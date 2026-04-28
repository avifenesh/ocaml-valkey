(* Integration tests for [Client.Config.connections_per_node].
   Live Valkey at :6379 (docker compose up -d). *)

module C = Valkey.Client
module E = Valkey.Connection.Error
module R = Valkey.Resp3

let host = "localhost"
let port = 6379

(* Build a client with [n] connections per node (standalone). *)
let with_client_n n f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config = { C.Config.default with connections_per_node = n } in
  let c = C.connect ~sw ~net ~clock ~config ~host ~port () in
  let r = f c in
  C.close c;
  r

let result_str = function
  | Ok v -> Format.asprintf "Ok %a" R.pp v
  | Error e -> Format.asprintf "Error %a" E.pp e

(* N = 1 behaves exactly like the default — no change expected. *)
let test_n_equals_one_round_trip () =
  with_client_n 1 @@ fun c ->
  match C.exec c [| "PING" |] with
  | Ok (R.Simple_string "PONG") -> ()
  | other -> Alcotest.failf "expected +PONG, got %s" (result_str other)

(* N = 4: a simple round-trip proves every bundle conn handshook
   successfully. If any of the 4 failed its HELLO/AUTH, the
   supervisor would close it and subsequent picks would surface a
   transport error on that conn. *)
let test_n_four_round_trip () =
  with_client_n 4 @@ fun c ->
  let key = "ocaml:conns_per_node:rt" in
  let _ = C.del c [ key ] in
  (match C.set c key "v1" with
   | Ok true -> ()
   | other -> Alcotest.failf "SET: %s"
                (match other with
                 | Ok b -> Printf.sprintf "Ok %b" b
                 | Error e -> Format.asprintf "Error %a" E.pp e));
  (match C.get c key with
   | Ok (Some "v1") -> ()
   | other ->
       Alcotest.failf "GET: %s"
         (match other with
          | Ok (Some s) -> Printf.sprintf "Ok (Some %S)" s
          | Ok None -> "Ok None"
          | Error e -> Format.asprintf "Error %a" E.pp e));
  let _ = C.del c [ key ] in
  ()

(* N = 4 under concurrency: 100 fibers, 50 GET/50 SET, all succeed.
   If round-robin picked a dead conn the test would surface the
   error; if pair-submit atomicity were broken, OPTIN-style pair
   commands would fail. Here we exercise just plain single-frame
   dispatch to confirm the per-command distribution path is live. *)
let test_n_four_concurrent () =
  with_client_n 4 @@ fun c ->
  let ok = ref 0 in
  let mutex = Mutex.create () in
  let work i () =
    let key = Printf.sprintf "ocaml:conns_per_node:conc:%d" i in
    let _ = C.del c [ key ] in
    (match C.set c key (Printf.sprintf "v%d" i) with
     | Ok true ->
         (match C.get c key with
          | Ok (Some s) when s = Printf.sprintf "v%d" i ->
              Mutex.lock mutex;
              incr ok;
              Mutex.unlock mutex
          | _ -> ())
     | _ -> ());
    let _ = C.del c [ key ] in
    ()
  in
  Eio.Fiber.all (List.init 100 (fun i -> work i));
  if !ok <> 100 then
    Alcotest.failf "expected 100 successful round-trips, got %d" !ok

let tests =
  [ "N=1 round-trip (baseline)",      `Quick, test_n_equals_one_round_trip;
    "N=4 round-trip",                 `Quick, test_n_four_round_trip;
    "N=4 under 100-fiber concurrency",`Quick, test_n_four_concurrent ]
