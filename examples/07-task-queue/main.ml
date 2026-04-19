(* Task queue on Valkey Streams + consumer groups.

   Producer adds tasks. Workers pull, process, ACK. A janitor
   fiber periodically scans for entries that have been pending
   too long (consumer crashed mid-task) and reclaims them via
   XAUTOCLAIM so they get processed by a healthy worker.

   This is a more elaborate version of 01-hello/streams_groups.ml,
   adding:
     - one "buggy" worker that fails halfway through processing
     - a janitor fiber demonstrating XAUTOCLAIM reclaim
     - a producer that runs concurrently with workers *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let stream = "queue:demo"
let group = "workers"
let janitor_consumer = "janitor"

let producer ~client ~clock ~n =
  for i = 0 to n - 1 do
    let body = Printf.sprintf "task-%03d" i in
    (match C.xadd client stream [ "body", body ] with
     | Ok id -> Printf.printf "[producer] %s -> %s\n%!" body id
     | Error e -> Format.eprintf "XADD: %a@." E.pp e);
    Eio.Time.sleep clock 0.05
  done;
  let _ = C.xadd client stream [ "body", "STOP" ] in
  ()

(* A worker. If [crash_at] = Some n, it processes the first n
   tasks then exits without ACKing the (n+1)-th. *)
let worker ~client ~clock ~name ?crash_at () =
  let rec loop processed =
    (match crash_at with
     | Some n when processed >= n ->
         Printf.printf "[%s] simulating crash after %d tasks\n%!"
           name processed;
         raise Exit
     | _ -> ());
    match
      C.xreadgroup client ~group ~consumer:name ~count:1
        ~streams:[ stream, ">" ]
    with
    | Error e ->
        Format.eprintf "[%s] XREADGROUP: %a@." name E.pp e;
        Eio.Time.sleep clock 0.5;
        loop processed
    | Ok [] | Ok [ _, [] ] ->
        Eio.Time.sleep clock 0.1;
        loop processed
    | Ok results ->
        let stop_seen = ref false in
        let new_processed = ref processed in
        List.iter
          (fun (_, entries) ->
            List.iter
              (fun (e : C.stream_entry) ->
                let body =
                  try List.assoc "body" e.fields with Not_found -> ""
                in
                if body = "STOP" then begin
                  stop_seen := true;
                  let _ = C.xack client stream ~group [ e.id ] in
                  ()
                end
                else begin
                  Printf.printf "[%s] processing %s = %s\n%!" name e.id body;
                  Eio.Time.sleep clock 0.1;
                  let _ = C.xack client stream ~group [ e.id ] in
                  incr new_processed
                end)
              entries)
          results;
        if !stop_seen then ()
        else loop !new_processed
  in
  try loop 0 with Exit -> ()

(* Reclaim entries pending longer than [stale_ms] from any
   consumer. Run periodically. *)
let janitor ~client ~clock =
  let stale_ms = 500 in
  let rec loop cursor =
    Eio.Time.sleep clock 0.3;
    match
      C.xautoclaim client stream ~group
        ~consumer:janitor_consumer ~min_idle_ms:stale_ms ~cursor
        ~count:32
    with
    | Error e ->
        Format.eprintf "[janitor] %a@." E.pp e;
        loop cursor
    | Ok r ->
        if r.claimed <> [] then
          Printf.printf
            "[janitor] reclaimed %d stale entries: %s\n%!"
            (List.length r.claimed)
            (String.concat ", "
               (List.map (fun (e : C.stream_entry) -> e.id) r.claimed));
        (* Re-process the claimed entries. In a real system the
           janitor would either re-deliver them on another channel
           or process them itself; here we just XACK to clear out. *)
        List.iter
          (fun (e : C.stream_entry) ->
            let _ = C.xack client stream ~group [ e.id ] in ())
          r.claimed;
        if r.next_cursor = "0-0" then loop "0-0"
        else loop r.next_cursor
  in
  loop "0-0"

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let make () =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in

  let admin = make () in
  let _ = C.del admin [ stream ] in
  (match
     C.xgroup_create admin stream ~group ~id:"$"
       ~opts:[ C.Xgroup_mkstream ]
   with
   | Ok () -> ()
   | Error _ -> () (* group already exists *));

  let p_client = make () in
  let buggy_client = make () in
  let healthy_client = make () in
  let janitor_client = make () in

  Eio.Fiber.all
    [ (fun () -> producer ~client:p_client ~clock ~n:10);
      (fun () -> worker ~client:buggy_client ~clock ~name:"buggy"
                   ~crash_at:3 ());
      (fun () -> worker ~client:healthy_client ~clock ~name:"healthy" ());
      (fun () ->
         (* Run the janitor for ~3s, then exit. *)
         Eio.Fiber.first
           (fun () -> janitor ~client:janitor_client ~clock)
           (fun () -> Eio.Time.sleep clock 3.0)) ];

  C.close admin;
  C.close p_client;
  C.close buggy_client;
  C.close healthy_client;
  C.close janitor_client
