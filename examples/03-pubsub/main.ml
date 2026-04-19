(* Pub/sub on a single Valkey instance.

   Two subscribers race for the same publish:
     - one with SUBSCRIBE on an exact channel
     - one with PSUBSCRIBE on a pattern that matches it

   A small publisher fiber emits 5 messages, then we shut down. *)

module C = Valkey.Client
module PS = Valkey.Pubsub
module E = Valkey.Connection.Error

let publisher ~client ~clock =
  for i = 0 to 4 do
    let msg = Printf.sprintf "event-%d" i in
    (match
       C.publish client ~channel:"events:demo" ~message:msg
     with
     | Ok n -> Printf.printf "[pub] %s -> %d subscribers got it\n%!" msg n
     | Error e -> Format.eprintf "[pub] %a@." E.pp e);
    Eio.Time.sleep clock 0.2
  done

let subscriber ~ps ~name =
  let rec loop () =
    match PS.next_message ~timeout:2.0 ps with
    | Ok (PS.Channel { channel; payload }) ->
        Printf.printf "[%s, channel] %s on %s\n%!" name payload channel;
        loop ()
    | Ok (PS.Pattern { pattern; channel; payload }) ->
        Printf.printf "[%s, pattern %s] %s on %s\n%!"
          name pattern payload channel;
        loop ()
    | Ok (PS.Shard _) -> loop ()
    | Error `Timeout ->
        (* No more deliveries within the window — the publisher has
           probably finished. Exit cleanly. *)
        Printf.printf "[%s] done.\n%!" name
  in
  loop ()

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in

  let make_pubsub () =
    PS.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in
  let make_client () =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in

  (* Subscribers first so they're listening before we publish. *)
  let s1 = make_pubsub () in
  let s2 = make_pubsub () in
  (match PS.subscribe s1 [ "events:demo" ] with
   | Ok () -> () | Error e -> Format.eprintf "subscribe: %a@." E.pp e);
  (match PS.psubscribe s2 [ "events:*" ] with
   | Ok () -> () | Error e -> Format.eprintf "psubscribe: %a@." E.pp e);

  (* Tiny breath so the SUBSCRIBE round-trips before the first publish. *)
  Eio.Time.sleep clock 0.1;

  let pub_client = make_client () in
  Eio.Fiber.all
    [ (fun () -> publisher ~client:pub_client ~clock);
      (fun () -> subscriber ~ps:s1 ~name:"sub1");
      (fun () -> subscriber ~ps:s2 ~name:"sub2") ];

  PS.close s1;
  PS.close s2;
  C.close pub_client
