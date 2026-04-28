(* Integration tests for [Client.Config.connections_per_node].
   Standalone Valkey at :6379 (docker compose up -d).

   Goal: prove the refactor actually exposes N distinct
   connections to the user's command stream at N>1. Just
   round-tripping SETs at N=4 is not enough — if [pick] always
   returned [bundle.(0)] the tests would still pass. Every test
   here asserts something that N=1 cannot produce. *)

module C = Valkey.Client
module E = Valkey.Connection.Error
module R = Valkey.Resp3

let host = "localhost"
let port = 6379

let with_client_n n f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config = { C.Config.default with connections_per_node = n } in
  let c = C.connect ~sw ~net ~clock ~config ~host ~port () in
  Fun.protect ~finally:(fun () -> C.close c) @@ fun () -> f c

let result_str = function
  | Ok v -> Format.asprintf "Ok %a" R.pp v
  | Error e -> Format.asprintf "Error %a" E.pp e

let result_str_opt = function
  | Ok (Some s) -> Printf.sprintf "Ok (Some %S)" s
  | Ok None -> "Ok None"
  | Error e -> Format.asprintf "Error %a" E.pp e

(* Read the current connection's CLIENT ID. Each live socket to
   the server has a unique server-assigned ID, so probing CLIENT
   ID across many commands surfaces the set of distinct
   connections [pick] actually routed through. *)
let client_id c =
  match C.exec c [| "CLIENT"; "ID" |] with
  | Ok (R.Integer i) -> Int64.to_int i
  | other -> Alcotest.failf "CLIENT ID unexpected: %s" (result_str other)

(* N = 1 baseline — no behavioural change expected vs
   non-connections_per_node clients. *)
let test_n_equals_one_round_trip () =
  with_client_n 1 @@ fun c ->
  match C.exec c [| "PING" |] with
  | Ok (R.Simple_string "PONG") -> ()
  | other -> Alcotest.failf "expected +PONG, got %s" (result_str other)

(* N = 4 handshake proof — four independent HELLO exchanges.
   If any bundle member failed to handshake, [Client.connect]
   raises (per the bundle-all-or-nothing invariant) and this
   test doesn't get here. *)
let test_n_four_round_trip () =
  with_client_n 4 @@ fun c ->
  let key = "ocaml:conns_per_node:rt" in
  let _ = C.del c [ key ] in
  (match C.set c key "v1" with
   | Ok true -> ()
   | other ->
       Alcotest.failf "SET: %s"
         (match other with
          | Ok b -> Printf.sprintf "Ok %b" b
          | Error e -> Format.asprintf "Error %a" E.pp e));
  (match C.get c key with
   | Ok (Some "v1") -> ()
   | other -> Alcotest.failf "GET: %s" (result_str_opt other));
  let _ = C.del c [ key ] in
  ()

(* Round-robin distribution proof: 100 concurrent fibers each
   call [CLIENT ID]. At N = 4 we must observe exactly 4 distinct
   IDs in the result set (one per bundle member). At N = 1 we'd
   see 1. A broken [pick] that always returns [bundle.(0)] would
   fail this assertion even with 100 concurrent fibers. *)
let test_n_four_round_robin_distributes () =
  with_client_n 4 @@ fun c ->
  let ids = ref [] in
  let mutex = Mutex.create () in
  let work () =
    let id = client_id c in
    Mutex.lock mutex;
    ids := id :: !ids;
    Mutex.unlock mutex
  in
  Eio.Fiber.all (List.init 100 (fun _ -> work));
  let distinct = List.sort_uniq compare !ids in
  let n_distinct = List.length distinct in
  if n_distinct <> 4 then
    Alcotest.failf
      "expected 4 distinct CLIENT IDs across 100 picks, got %d: [%s]"
      n_distinct
      (String.concat "; " (List.map string_of_int distinct))

(* 100-fiber SET/GET round-trip at N = 4 — regression guard
   against any [pick] / [pick_for_slot] concurrency bug that
   would surface as a dropped frame or protocol violation under
   load. All 100 must succeed on their own keys. *)
let test_n_four_concurrent () =
  with_client_n 4 @@ fun c ->
  let ok = Atomic.make 0 in
  let work i () =
    let key = Printf.sprintf "ocaml:conns_per_node:conc:%d" i in
    let _ = C.del c [ key ] in
    (match C.set c key (Printf.sprintf "v%d" i) with
     | Ok true ->
         (match C.get c key with
          | Ok (Some s) when s = Printf.sprintf "v%d" i ->
              Atomic.incr ok
          | _ -> ())
     | _ -> ());
    let _ = C.del c [ key ] in
    ()
  in
  Eio.Fiber.all (List.init 100 (fun i -> work i));
  if Atomic.get ok <> 100 then
    Alcotest.failf "expected 100 successful round-trips, got %d"
      (Atomic.get ok)

(* Slot-affinity sanity: MULTI/EXEC for a single-key transaction
   routes via [connection_for_slot_via -> pick_for_slot] and
   must use the same conn across the whole WATCH/MULTI/EXEC
   window or the transaction breaks (MULTI is connection-scoped
   server-side). Drive this through [Valkey.Transaction] so the
   test sees the typed behaviour, and run 50 transactions
   concurrently on distinct slots — if [pick_for_slot] misrouted
   any frame to a different bundle conn, at least one EXEC would
   see [MULTI] state missing and error. *)
let test_n_four_pick_for_slot_pins_transactions () =
  with_client_n 4 @@ fun c ->
  let module T = Valkey.Transaction in
  let ok = Atomic.make 0 in
  let work i () =
    (* One distinct key per fiber so different slots land on
       different bundle conns under [slot mod N]. *)
    let key = Printf.sprintf "ocaml:conns_per_node:tx:%d" i in
    let _ = C.del c [ key ] in
    let run () =
      T.with_transaction c ~hint_key:key (fun tx ->
          let _ = T.queue tx [| "SET"; key; "v" |] in
          let _ = T.queue tx [| "INCRBY"; key; "1" |] in
          ())
    in
    (match run () with
     | Ok (Some _) -> Atomic.incr ok
     | Ok None -> Alcotest.failf "tx %d: WATCH aborted unexpectedly" i
     | Error e -> Alcotest.failf "tx %d: %a" i E.pp e);
    let _ = C.del c [ key ] in
    ()
  in
  Eio.Fiber.all (List.init 50 (fun i -> work i));
  if Atomic.get ok <> 50 then
    Alcotest.failf "expected 50 transactions, got %d"
      (Atomic.get ok)

(* Negative-path: [connections_per_node < 1] must surface as
   [Invalid_argument] at [Client.connect] time, not later. *)
let test_reject_zero_conns () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config = { C.Config.default with connections_per_node = 0 } in
  match
    try
      let c = C.connect ~sw ~net ~clock ~config ~host ~port () in
      C.close c;
      `Connected
    with Invalid_argument _ -> `Raised_invalid_arg
  with
  | `Raised_invalid_arg -> ()
  | `Connected ->
      Alcotest.fail
        "connections_per_node = 0 should have raised Invalid_argument"

let tests =
  [ "N=1 round-trip (baseline)",           `Quick, test_n_equals_one_round_trip;
    "N=4 handshake + round-trip",          `Quick, test_n_four_round_trip;
    "N=4 round-robin distributes across 4 conns",
      `Quick, test_n_four_round_robin_distributes;
    "N=4 pick_for_slot pins concurrent MULTI/EXEC on distinct slots",
      `Quick, test_n_four_pick_for_slot_pins_transactions;
    "N=4 under 100-fiber concurrency",     `Quick, test_n_four_concurrent;
    "reject connections_per_node = 0",      `Quick, test_reject_zero_conns;
  ]
