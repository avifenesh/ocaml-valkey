(* Streams + consumer groups.

   A consumer group lets multiple workers split a stream's entries
   between them. Each entry is delivered to exactly one consumer
   in the group. The worker XACKs after processing.

   This demo runs a producer fiber and two worker fibers in the
   same process so it's self-contained — in real life the workers
   would be separate processes. *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let stream = "tasks:hello-groups"
let group = "workers"

let producer ~client ~clock =
  for i = 0 to 9 do
    let body = Printf.sprintf "task-%d" i in
    (match C.xadd client stream [ "body", body ] with
     | Ok id -> Printf.printf "[producer] %s -> %s\n%!" body id
     | Error e -> Format.eprintf "XADD: %a@." E.pp e);
    Eio.Time.sleep clock 0.1
  done;
  (* Sentinel: empty entry so workers know to stop after this. *)
  let _ = C.xadd client stream [ "body", "STOP" ] in
  ()

let worker ~client ~clock ~name =
  let rec loop () =
    match
      C.xreadgroup client ~group ~consumer:name ~count:2
        ~streams:[ stream, ">" ]
    with
    | Error e ->
        Format.eprintf "[%s] XREADGROUP: %a@." name E.pp e;
        Eio.Time.sleep clock 0.5;
        loop ()
    | Ok [] | Ok [ _, [] ] ->
        (* Brief pause when the stream is empty. Real workers would
           use XREADGROUP with BLOCK; see lib/client.mli xreadgroup_block. *)
        Eio.Time.sleep clock 0.2;
        loop ()
    | Ok results ->
        let stop_seen = ref false in
        List.iter
          (fun (_s, entries) ->
            List.iter
              (fun (e : C.stream_entry) ->
                let body =
                  try List.assoc "body" e.fields with Not_found -> ""
                in
                Printf.printf "[%s] processing %s = %s\n%!" name e.id body;
                if body = "STOP" then stop_seen := true;
                let _ =
                  C.xack client stream ~group [ e.id ]
                in ())
              entries)
          results;
        if not !stop_seen then loop ()
  in
  loop ()

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let make_client () =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in

  (* Each fiber gets its own client because XREADGROUP holds the
     connection while waiting (we don't use BLOCK here, but it's
     still good practice for stream workers). *)
  let admin = make_client () in
  let _ = C.del admin [ stream ] in
  (* MKSTREAM creates the stream lazily if it doesn't exist. *)
  (match
     C.xgroup_create admin stream ~group ~id:"$"
       ~opts:[ C.Xgroup_mkstream ]
   with
   | Ok () | Error (E.Server_error { code = _; _ }) -> ()
   | Error e -> Format.eprintf "xgroup_create: %a@." E.pp e);

  let p_client = make_client () in
  let w1_client = make_client () in
  let w2_client = make_client () in

  Eio.Fiber.all
    [ (fun () -> producer ~client:p_client ~clock);
      (fun () -> worker ~client:w1_client ~clock ~name:"w1");
      (fun () -> worker ~client:w2_client ~clock ~name:"w2") ];

  C.close admin;
  C.close p_client;
  C.close w1_client;
  C.close w2_client
