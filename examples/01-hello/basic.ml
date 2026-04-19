(* Hello, Valkey.

   Connect to a local instance, do the simplest possible read/write,
   show how to handle the three reply shapes (Ok value / Ok None /
   Error). *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in

  (* SET returns true on success; false if NX/XX/IFEQ blocked it. *)
  (match C.set client "hello:greeting" "world" with
   | Ok true -> print_endline "SET ok"
   | Ok false -> print_endline "SET refused (NX/XX)"
   | Error e -> Format.eprintf "SET: %a@." E.pp e);

  (* GET returns string option. None means the key is missing. *)
  (match C.get client "hello:greeting" with
   | Ok (Some v) -> Printf.printf "GET -> %s\n" v
   | Ok None -> print_endline "GET -> (nil)"
   | Error e -> Format.eprintf "GET: %a@." E.pp e);

  (* INCR atomically increments a counter. INCRBY for steps != 1. *)
  for _ = 1 to 5 do
    match C.incr client "hello:counter" with
    | Ok n -> Printf.printf "INCR -> %Ld\n" n
    | Error e -> Format.eprintf "INCR: %a@." E.pp e
  done;

  (* SET with TTL via the typed ttl variant. *)
  let _ =
    C.set client "hello:short" "expires soon"
      ~ttl:(C.Set_ex_seconds 5)
  in

  (* Tear-down: closing the switch closes the client too, but
     [close] is also fine to call explicitly. Idempotent. *)
  C.close client
