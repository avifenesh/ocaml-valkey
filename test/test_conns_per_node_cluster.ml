(** Cluster-mode integration tests for
    [connections_per_node] at N>1.

    The standalone tests ([test_conns_per_node.ml]) prove
    round-robin + pick_for_slot transaction pinning against one
    Valkey. But the motivating design paths for
    [pick_for_slot] — OPTIN CSC [CACHING YES + read] pair, ASK
    redirect [CACHING YES + ASKING + read] triple, MULTI/EXEC
    cluster pinning, topology-refresh bundle rebuild — live in
    [Cluster_router] and only exist under cluster mode.

    Every test below runs at [connections_per_node = 4] and
    asserts behaviour that a broken [pick_for_slot] (e.g.
    accidental round-robin on a pair submit, or a partial
    bundle after a refresh) would break. *)

module C = Valkey.Client
module Cfg = Valkey.Client.Config
module Cache = Valkey.Cache
module CC = Valkey.Client_cache
module CR = Valkey.Cluster_router
module Conn = Valkey.Connection
module E = Valkey.Connection.Error
module R = Valkey.Resp3

let seeds = Test_support.seeds
let cluster_reachable = Test_support.cluster_reachable
let skipped = Test_support.skipped

let grace_s = 0.1
let n_conns = 4

(* Build a cluster client with [connections_per_node = n_conns]
   and a shared CSC cache. Mirrors [test_csc_optin_cluster.ml]'s
   [with_optin_cluster] but threads the new knob. *)
let with_cluster_n ~keys ~mode f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let cache = Cache.create ~byte_budget:(1024 * 1024) in
  let ccfg = CC.make ~cache ~mode () in
  let cluster_cfg =
    let d = CR.Config.default ~seeds in
    { d with
      connection = { d.connection with client_cache = Some ccfg };
      connections_per_node = n_conns }
  in
  let router =
    match CR.create ~sw ~net ~clock ~config:cluster_cfg () with
    | Ok r -> r
    | Error e -> Alcotest.failf "cluster router: %s" e
  in
  let client =
    C.from_router
      ~config:{ Cfg.default with
                connection = cluster_cfg.connection;
                connections_per_node = n_conns }
      router
  in
  let aux_router =
    match CR.create ~sw ~net ~clock ~config:(CR.Config.default ~seeds) ()
    with
    | Ok r -> r
    | Error e -> Alcotest.failf "aux router: %s" e
  in
  let aux = C.from_router ~config:Cfg.default aux_router in
  let cleanup () = List.iter (fun k -> let _ = C.del aux [k] in ()) keys in
  cleanup ();
  let finally () = cleanup (); C.close client; C.close aux in
  Fun.protect ~finally (fun () -> f env client cache aux)

(* Sleep helper, uses Eio clock so switches yield. *)
let sleep env ms = Eio.Time.sleep (Eio.Stdenv.clock env) (ms /. 1000.0)

(* --- Test 1: OPTIN pair-submit atomicity at N=4 -----------

   The OPTIN read path submits [CLIENT CACHING YES] + [GET] as
   a single wire-adjacent pair via
   [Connection.request_pair].  [Router.pair] uses
   [pick_for_slot] to ensure both frames land on the same
   bundle conn; if they split across conns, CACHING YES would
   arm conn A and GET would run on conn B untracked.  An
   external SET from [aux] would then fail to invalidate the
   cache entry, surfacing as stale data.

   The test: 20 distinct keys across varied slots get cached
   via OPTIN, then aux-SET flips their values, and we assert
   every one of the 20 cache entries evicts within the grace
   window.  Broken pair-submit atomicity would miss
   invalidations on the conns where CACHING YES didn't arm. *)
let test_optin_pair_atomicity_at_n4 () =
  if not (cluster_reachable ()) then
    skipped "cluster-N4: OPTIN pair atomicity"
  else
    let keys =
      List.init 20 (fun i ->
          Printf.sprintf "{csc-n4-%d}:ocaml:csc:optin:n4:%d" i i)
    in
    with_cluster_n ~keys ~mode:CC.Optin
    @@ fun env client cache aux ->
    (* Seed values and warm the cache. *)
    List.iteri (fun i k ->
        let _ = C.exec aux [| "SET"; k; Printf.sprintf "v%d" i |] in
        ()) keys;
    List.iter (fun k ->
        match C.get client k with
        | Ok (Some _) -> ()
        | other ->
            Alcotest.failf "warm-read %S: %s" k
              (match other with
               | Ok None -> "None"
               | Ok (Some s) -> Printf.sprintf "Some %S" s
               | Error e -> Format.asprintf "Error %a" E.pp e))
      keys;
    Alcotest.(check int) "all 20 cached after warm-read" 20
      (Cache.count cache);
    (* External writes must invalidate every one. *)
    List.iteri (fun i k ->
        let _ = C.exec aux [| "SET"; k; Printf.sprintf "w%d" i |] in
        ()) keys;
    (* Wait for invalidations to propagate through per-conn
       streams into the shared cache. *)
    let deadline = Unix.gettimeofday () +. 2.0 in
    let rec wait_for_drain () =
      if Cache.count cache = 0 then ()
      else if Unix.gettimeofday () > deadline then
        Alcotest.failf
          "expected all 20 entries evicted within 2s, %d still cached"
          (Cache.count cache)
      else (sleep env 20.0; wait_for_drain ())
    in
    wait_for_drain ()

(* --- Test 2: MULTI/EXEC at N=4 across many slots -----------

   [connection_for_slot_via] now routes through
   [pick_for_slot].  A cluster MULTI/EXEC on slot S must stay
   on the single conn [bundle.(S mod N)] from MULTI through
   EXEC; if any frame misroutes, the server errors (MULTI
   context is connection-scoped).

   Run 30 concurrent transactions on keys that land across
   many slots.  Every one must commit. *)
let test_multi_exec_pinned_at_n4 () =
  if not (cluster_reachable ()) then
    skipped "cluster-N4: MULTI/EXEC pinned"
  else
    let keys =
      List.init 30 (fun i ->
          Printf.sprintf "{tx-n4-%d}:ocaml:tx:n4:%d" i i)
    in
    with_cluster_n ~keys ~mode:CC.Default
    @@ fun _env client _cache aux ->
    let module T = Valkey.Transaction in
    let ok = Atomic.make 0 in
    let work key =
      let _ = C.del aux [ key ] in
      let r =
        T.with_transaction client ~hint_key:key (fun tx ->
            let _ = T.queue tx [| "SET"; key; "v" |] in
            let _ = T.queue tx [| "INCRBY"; key; "1" |] in
            ())
      in
      (match r with
       | Ok (Some _) -> Atomic.incr ok
       | Ok None -> Alcotest.failf "tx %s: WATCH aborted" key
       | Error e -> Alcotest.failf "tx %s: %a" key E.pp e)
    in
    Eio.Fiber.all (List.map (fun k () -> work k) keys);
    if Atomic.get ok <> List.length keys then
      Alcotest.failf "expected %d successful transactions, got %d"
        (List.length keys) (Atomic.get ok)

(* --- Test 3: per-conn invalidations reach shared cache -----

   At N=4 each node has 4 independent RESP3 invalidation
   streams, each drained by its own per-conn invalidator
   fiber.  Every stream must feed the single shared [Cache.t]
   (we can't tell which conn the server sent the push on).  If
   a future refactor accidentally only drains one conn's
   stream, this test catches it: we warm the cache via the
   client, then modify each key from aux, and assert the cache
   drains fully. *)
let test_shared_cache_drain_across_bundle_streams () =
  if not (cluster_reachable ()) then
    skipped "cluster-N4: shared cache drain"
  else
    let keys =
      List.init 40 (fun i ->
          Printf.sprintf "{drain-n4-%d}:ocaml:drain:n4:%d" i i)
    in
    with_cluster_n ~keys ~mode:CC.Default
    @@ fun env client cache aux ->
    List.iter (fun k ->
        let _ = C.exec aux [| "SET"; k; "seed" |] in ()) keys;
    List.iter (fun k ->
        match C.get client k with
        | Ok (Some _) -> ()
        | _ -> ()) keys;
    Alcotest.(check int) "all keys cached" (List.length keys)
      (Cache.count cache);
    List.iter (fun k ->
        let _ = C.exec aux [| "SET"; k; "new" |] in ()) keys;
    let deadline = Unix.gettimeofday () +. 2.0 in
    let rec wait () =
      if Cache.count cache = 0 then ()
      else if Unix.gettimeofday () > deadline then
        Alcotest.failf "expected cache to drain, %d still present"
          (Cache.count cache)
      else (sleep env 20.0; wait ())
    in
    wait ()

let tests =
  [ "N=4: OPTIN pair-submit atomicity (20 keys, all must evict)",
      `Slow, test_optin_pair_atomicity_at_n4;
    "N=4: MULTI/EXEC pinned across 30 concurrent slots",
      `Slow, test_multi_exec_pinned_at_n4;
    "N=4: shared cache drains invalidations from all bundle streams",
      `Slow, test_shared_cache_drain_across_bundle_streams;
  ]
