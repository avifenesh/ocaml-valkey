(* Tests for Valkey.Batch: scatter-gather batch primitive and the
   typed cluster-aware helpers built on top.

   Runs against the docker-compose cluster. *)

module C = Valkey.Client
module CR = Valkey.Cluster_router
module B = Valkey.Batch
module E = Valkey.Connection.Error
module Conn = Valkey.Connection

let seeds = [ "valkey-c1", 7000; "valkey-c2", 7001; "valkey-c3", 7002 ]

let force_skip () =
  try Sys.getenv "VALKEY_CLUSTER" = "skip" with Not_found -> false

let cluster_reachable () =
  if force_skip () then false
  else
    try
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let (host, port) = List.hd seeds in
      let conn =
        Conn.connect ~sw
          ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
          ~config:Conn.Config.default ~host ~port ()
      in
      Conn.close conn;
      true
    with _ -> false

let with_cluster_client f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config =
    { (CR.Config.default ~seeds) with prefer_hostname = true }
  in
  match CR.create ~sw ~net ~clock ~config () with
  | Error m -> Alcotest.failf "Cluster_router.create: %s" m
  | Ok router ->
      let client = C.from_router ~config:C.Config.default router in
      Fun.protect ~finally:(fun () -> C.close client) @@ fun () -> f client

let err_pp = E.pp

(* 500 spread keys: mset_cluster populates, mget_cluster fetches
   them back, del_cluster wipes. No hashtags — each key lands on
   a random slot, so this exercises the per-slot bucketing +
   parallel dispatch across every primary. *)
let test_mset_mget_del_roundtrip () =
  with_cluster_client @@ fun client ->
  let n = 500 in
  let kvs =
    List.init n
      (fun i ->
        Printf.sprintf "batch:demo:%d" i,
        Printf.sprintf "v-%d" i)
  in
  let keys = List.map fst kvs in

  (* Pre-clean so partial state from earlier runs doesn't skew us. *)
  let _ = B.del_cluster client keys in

  (match B.mset_cluster client kvs with
   | Ok () -> ()
   | Error e -> Alcotest.failf "mset_cluster: %a" err_pp e);

  (match B.mget_cluster client keys with
   | Error e -> Alcotest.failf "mget_cluster: %a" err_pp e
   | Ok pairs ->
       Alcotest.(check int) "length" n (List.length pairs);
       List.iter2
         (fun (exp_k, exp_v) (got_k, got_v) ->
           Alcotest.(check string) "key order" exp_k got_k;
           match got_v with
           | Some v when v = exp_v -> ()
           | Some other ->
               Alcotest.failf "mget %s: expected %s, got %s"
                 exp_k exp_v other
           | None ->
               Alcotest.failf "mget %s: missing" exp_k)
         kvs pairs);

  match B.del_cluster client keys with
  | Ok n_removed ->
      Alcotest.(check int) "del_cluster count" n n_removed
  | Error e ->
      Alcotest.failf "del_cluster: %a" err_pp e

(* Heterogeneous batch: mix GET / SET / INCR / HSET across slots.
   Each queued command keeps its own result; we unwrap the
   variant and check decoded values. *)
let test_heterogeneous_batch () =
  with_cluster_client @@ fun client ->
  let _ = B.del_cluster client [ "het:a"; "het:b"; "het:c"; "het:h" ] in

  let b = B.create () in
  let q args =
    match B.queue b args with
    | Ok () -> ()
    | Error _ ->
        Alcotest.fail "queue rejected in non-atomic mode (unexpected)"
  in
  q [| "SET"; "het:a"; "one" |];
  q [| "SET"; "het:b"; "two" |];
  q [| "INCR"; "het:c" |];
  q [| "HSET"; "het:h"; "name"; "ada" |];
  q [| "GET"; "het:a" |];
  q [| "GET"; "het:c" |];

  (match B.run client b with
   | Error e -> Alcotest.failf "run: %a" err_pp e
   | Ok None -> Alcotest.fail "unexpected atomic abort"
   | Ok (Some rs) ->
       Alcotest.(check int) "result count" 6 (Array.length rs);
       (* SET should return +OK (Simple_string). *)
       (match rs.(0) with
        | B.One (Ok (Valkey.Resp3.Simple_string "OK")) -> ()
        | _ -> Alcotest.fail "rs.0: expected SET OK");
       (* INCR returns an integer. *)
       (match rs.(2) with
        | B.One (Ok (Valkey.Resp3.Integer 1L)) -> ()
        | _ -> Alcotest.fail "rs.2: expected INCR 1");
       (* HSET returns count of new fields. *)
       (match rs.(3) with
        | B.One (Ok (Valkey.Resp3.Integer 1L)) -> ()
        | _ -> Alcotest.fail "rs.3: expected HSET 1");
       (* GET het:a -> "one" *)
       (match rs.(4) with
        | B.One (Ok (Valkey.Resp3.Bulk_string "one")) -> ()
        | _ -> Alcotest.fail "rs.4: expected GET one");
       (* GET het:c -> "1" *)
       (match rs.(5) with
        | B.One (Ok (Valkey.Resp3.Bulk_string "1")) -> ()
        | _ -> Alcotest.fail "rs.5: expected GET 1"));

  let _ = B.del_cluster client [ "het:a"; "het:b"; "het:c"; "het:h" ] in
  ()

(* Atomic mode rejects fan-out commands at queue time with a
   structured error naming the offending command. *)
let test_atomic_rejects_fan_out () =
  (* Pure logic — no cluster needed; the rejection happens in
     Batch.queue before any dispatch. *)
  let b = B.create ~atomic:true ~hint_key:"x" () in
  match B.queue b [| "SCRIPT"; "LOAD"; "return 1" |] with
  | Error (B.Fan_out_in_atomic_batch name) ->
      Alcotest.(check string) "command name" "SCRIPT" name
  | Ok () ->
      Alcotest.fail "atomic batch accepted a fan-out command (SCRIPT LOAD)"

(* Atomic mode isn't wired yet; confirm the placeholder error is
   what we documented so callers know to reach for Transaction. *)
let test_atomic_not_yet_implemented () =
  with_cluster_client @@ fun client ->
  let b = B.create ~atomic:true ~hint_key:"x" () in
  let _ = B.queue b [| "GET"; "x" |] in
  match B.run client b with
  | Error (E.Terminal msg) when
      String.length msg >= 10 && String.sub msg 0 10 = "Batch.run:" ->
      ()
  | r ->
      Alcotest.failf
        "expected Terminal 'Batch.run: ...' placeholder; got %s"
        (match r with
         | Ok _ -> "Ok"
         | Error e -> Format.asprintf "Error %a" err_pp e)

let skip_placeholder name () =
  Printf.printf
    "[skipped] %s (cluster unreachable; docker-compose.cluster.yml)\n%!"
    name

let tests =
  let reachable = cluster_reachable () in
  let tc name f =
    if reachable then Alcotest.test_case name `Quick f
    else Alcotest.test_case name `Quick (skip_placeholder name)
  in
  (* The fan-out rejection test is cluster-independent; always run. *)
  [ Alcotest.test_case "atomic batch rejects fan-out at queue time"
      `Quick test_atomic_rejects_fan_out;
    tc "mset / mget / del cluster round-trip (500 keys)"
      test_mset_mget_del_roundtrip;
    tc "heterogeneous batch (GET / SET / INCR / HSET)"
      test_heterogeneous_batch;
    tc "atomic mode returns Terminal placeholder for 0.2"
      test_atomic_not_yet_implemented;
  ]
