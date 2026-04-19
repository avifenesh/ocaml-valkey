(* Blocking commands.

   BLPOP / BRPOP let a worker wait on a list with a timeout. The
   worker fiber is suspended until either:
     - someone LPUSHes onto the watched list
     - the block_seconds timeout fires (server-side)
     - the per-call ?timeout fires (client-side, raises Timeout)

   The exclusive-connection rule: a client whose connection is
   blocked inside BLPOP can't service other commands. Open a
   dedicated Client.t for the worker. *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let queue = "demo:blocking"

let producer ~client ~clock =
  for i = 0 to 4 do
    Eio.Time.sleep clock 0.5;
    let job = Printf.sprintf "job-%d" i in
    (match C.lpush client queue [ job ] with
     | Ok n -> Printf.printf "[producer] pushed %s (queue len now %d)\n%!" job n
     | Error e -> Format.eprintf "LPUSH: %a@." E.pp e)
  done

let worker ~client =
  let rec loop seen =
    if seen >= 5 then begin
      Printf.printf "[worker] processed 5 jobs, exiting\n%!";
    end
    else
      match
        C.brpop client ~keys:[ queue ] ~block_seconds:1.0
      with
      | Ok (Some (_q, job)) ->
          Printf.printf "[worker] got %s\n%!" job;
          loop (seen + 1)
      | Ok None ->
          Printf.printf "[worker] BRPOP server-side timeout, retrying\n%!";
          loop seen
      | Error e ->
          Format.eprintf "[worker] BRPOP: %a@." E.pp e
  in
  loop 0

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let make () =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in

  let setup = make () in
  let _ = C.del setup [ queue ] in
  C.close setup;

  (* Two clients — the worker's connection will be tied up inside
     BRPOP, so the producer needs its own. *)
  let producer_client = make () in
  let worker_client = make () in
  Eio.Fiber.both
    (fun () -> producer ~client:producer_client ~clock)
    (fun () -> worker ~client:worker_client);
  C.close producer_client;
  C.close worker_client
