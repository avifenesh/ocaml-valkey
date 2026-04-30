(* Integration tests for Client.Config.blocking_pool +
   Client.blpop / brpop / blmove / xread_block /
   with_dedicated_conn / wait_replicas_on.

   Covers the full matrix of the Blocking_pool refactor:
     - happy-path data-ready and timeout via the pool
     - Pool_not_configured, Pool_exhausted, Borrow_timeout,
       Node_gone error paths
     - Cross_slot rejection (cluster-only)
     - WAIT's typed Wait_needs_dedicated_conn error + the
       with_dedicated_conn + wait_replicas_on happy path

   Cluster-dependent tests skip when docker-compose.cluster
   isn't up ([Test_support.cluster_reachable]). *)

module C = Valkey.Client
module BP = Valkey.Blocking_pool
module E = Valkey.Connection.Error
module R = Valkey.Resp3

let host = "localhost"
let port = 6379

(* Standalone-Client builder. [cfg_f] lets the caller tweak
   [Blocking_pool.Config] per test. *)
let with_client ?(pool = BP.Config.default) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config = { C.Config.default with blocking_pool = pool } in
  let c = C.connect ~sw ~net ~clock ~config ~host ~port () in
  let r =
    try f env clock c
    with e -> C.close c; raise e
  in
  C.close c;
  r

let seeds = Test_support.seeds
let cluster_reachable = Test_support.cluster_reachable
let skipped = Test_support.skipped

let with_cluster_client ?(pool = BP.Config.default) f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let pool_ref = ref None in
  let cr_config = {
    (Valkey.Cluster_router.Config.default ~seeds) with
    topology_hooks =
      C.topology_hooks_for_pool_ref pool_ref;
  } in
  let router =
    match
      Valkey.Cluster_router.create ~sw ~net ~clock ~config:cr_config ()
    with
    | Ok r -> r
    | Error s -> Alcotest.failf "cluster_router: %s" s
  in
  let client_config = { C.Config.default with blocking_pool = pool } in
  let c =
    C.from_router ~sw ~net ~clock ~config:client_config router
  in
  pool_ref := C.For_testing.blocking_pool c;
  let r =
    try f env clock c
    with e -> C.close c; raise e
  in
  C.close c;
  r

(* Pool config opened up for blocking; used by most tests. *)
let pool_on ?(max_per_node = 2) ?(on_exhaustion = `Block)
    ?(borrow_timeout = Some 2.0) () =
  { BP.Config.default with
    max_per_node; on_exhaustion; borrow_timeout }

(* ---------- Tests 1-2: data-ready + timeout on standalone ---------- *)

let test_blpop_data_ready () =
  with_client ~pool:(pool_on ()) @@ fun _env _clock c ->
  let key = "ocaml:bpi:blpop:ready" in
  let _ = C.del c [ key ] in
  ignore (C.rpush c key [ "v1" ]);
  (match C.blpop c ~keys:[ key ] ~block_seconds:0.5 with
   | Ok (Some (k, v)) when k = key && v = "v1" -> ()
   | Ok other ->
       Alcotest.failf "BLPOP: %s"
         (match other with
          | Some (k, v) -> Printf.sprintf "Some (%S, %S)" k v
          | None -> "None")
   | Error e ->
       Alcotest.failf "BLPOP: %a" C.pp_blocking_error e);
  let _ = C.del c [ key ] in
  ()

let test_blpop_timeout_clean_return () =
  with_client ~pool:(pool_on ()) @@ fun _env _clock c ->
  let key = "ocaml:bpi:blpop:timeout" in
  let _ = C.del c [ key ] in
  (match C.blpop c ~keys:[ key ] ~block_seconds:0.1 with
   | Ok None -> ()
   | Ok (Some (k, v)) ->
       Alcotest.failf "BLPOP expected timeout, got Some (%S, %S)" k v
   | Error e ->
       Alcotest.failf "BLPOP: %a" C.pp_blocking_error e);
  (* Pool stats: the lease succeeded (total_borrowed >= 1) and
     the conn is now back in idle (no dirty close). *)
  (match C.For_testing.blocking_pool c with
   | None -> Alcotest.fail "blocking_pool should be Some _"
   | Some pool ->
       let s = BP.stats pool in
       if s.total_borrowed < 1 then
         Alcotest.failf "expected total_borrowed >= 1, got %d"
           s.total_borrowed;
       if s.total_closed_dirty > 0 then
         Alcotest.failf
           "expected no dirty closes on a clean timeout, got %d"
           s.total_closed_dirty;
       if s.idle < 1 then
         Alcotest.failf "expected idle >= 1 after clean return, got %d"
           s.idle)

(* ---------- Test 3: Pool_not_configured ---------- *)

let test_pool_not_configured () =
  (* Default config: max_per_node = 0, pool is None. *)
  with_client @@ fun _env _clock c ->
  let key = "ocaml:bpi:notcfg" in
  let _ = C.del c [ key ] in
  match C.blpop c ~keys:[ key ] ~block_seconds:0.1 with
  | Error (C.Pool BP.Pool_not_configured) -> ()
  | Ok _ ->
      Alcotest.fail
        "BLPOP on default config should surface Pool_not_configured"
  | Error e ->
      Alcotest.failf "expected Pool_not_configured, got %a"
        C.pp_blocking_error e

(* ---------- Test 4: Pool_exhausted under Fail_fast ---------- *)

let test_pool_exhausted_fail_fast () =
  let pool =
    pool_on ~max_per_node:1 ~on_exhaustion:`Fail_fast
      ~borrow_timeout:(Some 0.0) ()
  in
  with_client ~pool @@ fun _env _clock c ->
  let k1 = "ocaml:bpi:ex:1" in
  let k2 = "ocaml:bpi:ex:2" in
  let _ = C.del c [ k1; k2 ] in
  let second_err = Atomic.make None in
  Eio.Fiber.both
    (fun () ->
      (* Holds the single pool conn for ~0.5 s on an empty key. *)
      let _ = C.blpop c ~keys:[ k1 ] ~block_seconds:0.5 in
      ())
    (fun () ->
      (* Give the first fiber time to lease the only slot. *)
      Unix.sleepf 0.05;
      match C.blpop c ~keys:[ k2 ] ~block_seconds:0.1 with
      | Error (C.Pool BP.Pool_exhausted) ->
          Atomic.set second_err (Some `Exhausted)
      | Ok _ ->
          Atomic.set second_err (Some `UnexpectedOk)
      | Error e ->
          Atomic.set second_err
            (Some
               (`Other (Format.asprintf "%a" C.pp_blocking_error e))));
  match Atomic.get second_err with
  | Some `Exhausted -> ()
  | Some `UnexpectedOk ->
      Alcotest.fail "second BLPOP should have been Pool_exhausted, got Ok"
  | Some (`Other s) ->
      Alcotest.failf "second BLPOP: expected Pool_exhausted, got %s" s
  | None ->
      Alcotest.fail "second BLPOP did not run"

(* ---------- Test 5: Borrow_timeout under Block ---------- *)

let test_borrow_timeout_block () =
  let pool =
    pool_on ~max_per_node:1 ~on_exhaustion:`Block
      ~borrow_timeout:(Some 0.05) ()
  in
  with_client ~pool @@ fun _env _clock c ->
  let k1 = "ocaml:bpi:bt:1" in
  let k2 = "ocaml:bpi:bt:2" in
  let _ = C.del c [ k1; k2 ] in
  let second_err = Atomic.make None in
  Eio.Fiber.both
    (fun () ->
      let _ = C.blpop c ~keys:[ k1 ] ~block_seconds:0.5 in ())
    (fun () ->
      Unix.sleepf 0.02;
      match C.blpop c ~keys:[ k2 ] ~block_seconds:0.1 with
      | Error (C.Pool BP.Borrow_timeout) ->
          Atomic.set second_err (Some `Timeout)
      | Ok _ ->
          Atomic.set second_err (Some `UnexpectedOk)
      | Error e ->
          Atomic.set second_err
            (Some
               (`Other (Format.asprintf "%a" C.pp_blocking_error e))));
  match Atomic.get second_err with
  | Some `Timeout -> ()
  | Some `UnexpectedOk ->
      Alcotest.fail "second BLPOP should have been Borrow_timeout, got Ok"
  | Some (`Other s) ->
      Alcotest.failf "second BLPOP: expected Borrow_timeout, got %s" s
  | None ->
      Alcotest.fail "second BLPOP did not run"

(* ---------- Test 6: Node_gone after drain_node ---------- *)

let test_node_gone_after_drain () =
  with_client ~pool:(pool_on ()) @@ fun _env _clock c ->
  (* Warm one conn so the bucket exists. *)
  let key = "ocaml:bpi:drain" in
  let _ = C.del c [ key ] in
  (match C.blpop c ~keys:[ key ] ~block_seconds:0.05 with
   | Ok _ | Error _ -> ());
  (match C.For_testing.blocking_pool c with
   | None -> Alcotest.fail "blocking_pool should be Some _"
   | Some pool ->
       BP.drain_node pool
         ~node_id:Valkey.Topology.standalone_node_id);
  match C.blpop c ~keys:[ key ] ~block_seconds:0.05 with
  | Error (C.Pool BP.Node_gone) -> ()
  | Ok _ ->
      Alcotest.fail "post-drain BLPOP should be Node_gone, got Ok"
  | Error e ->
      Alcotest.failf "post-drain BLPOP: expected Node_gone, got %a"
        C.pp_blocking_error e

(* ---------- Test 7: Exec error closes the leased conn ---------- *)

let test_exec_error_closes_conn () =
  let pool = pool_on ~max_per_node:1 () in
  with_client ~pool @@ fun _env _clock c ->
  let key = "ocaml:bpi:wrongtype" in
  let _ = C.del c [ key ] in
  (* Create a string at key, then run BLPOP on it → WRONGTYPE. *)
  (match C.set c key "x" with
   | Ok _ -> ()
   | Error e -> Alcotest.failf "SET: %a" E.pp e);
  (match C.blpop c ~keys:[ key ] ~block_seconds:0.1 with
   | Error (C.Exec (E.Server_error ve))
     when ve.code = "WRONGTYPE" -> ()
   | Ok _ -> Alcotest.fail "expected WRONGTYPE"
   | Error e ->
       Alcotest.failf "expected Exec WRONGTYPE, got %a"
         C.pp_blocking_error e);
  (* The leased conn must have been closed (dirty), so pool
     stats show total_closed_dirty >= 1. *)
  (match C.For_testing.blocking_pool c with
   | None -> Alcotest.fail "blocking_pool should be Some _"
   | Some pool ->
       let s = BP.stats pool in
       if s.total_closed_dirty < 1 then
         Alcotest.failf
           "expected total_closed_dirty >= 1 after WRONGTYPE, got %d"
           s.total_closed_dirty);
  let _ = C.del c [ key ] in
  ()

(* ---------- Test 8: WAIT returns Wait_needs_dedicated_conn ---------- *)

let test_wait_needs_dedicated () =
  with_client ~pool:(pool_on ()) @@ fun _env _clock c ->
  match C.wait_replicas c ~num_replicas:0 ~block_ms:100 with
  | Error (C.Wait_needs_dedicated_conn _) -> ()
  | Ok n ->
      Alcotest.failf
        "WAIT: expected Wait_needs_dedicated_conn, got Ok %d" n
  | Error e ->
      Alcotest.failf "WAIT: expected Wait_needs_dedicated_conn, got %a"
        C.pp_blocking_error e

(* ---------- Test 9: with_dedicated_conn + wait_replicas_on ---------- *)

let test_wait_via_dedicated () =
  with_client ~pool:(pool_on ()) @@ fun _env _clock c ->
  let key = "ocaml:bpi:wait:dedicated" in
  let r =
    C.with_dedicated_conn c (fun conn ->
        match
          Valkey.Connection.request conn [| "SET"; key; "v" |]
        with
        | Error e -> Error e
        | Ok _ ->
            C.wait_replicas_on conn ~num_replicas:0 ~block_ms:100)
  in
  (match r with
   | Ok n when n >= 0 -> ()
   | Ok n ->
       Alcotest.failf "expected >=0 ack count, got %d" n
   | Error e ->
       Alcotest.failf "with_dedicated_conn: %a"
         C.pp_blocking_error e);
  let _ = C.del c [ key ] in
  ()

(* ---------- Test 10: xread_block single-stream via pool ---------- *)

let test_xread_block_single_stream () =
  with_client ~pool:(pool_on ()) @@ fun _env _clock c ->
  let key = "ocaml:bpi:xread:single" in
  let _ = C.del c [ key ] in
  match C.xread_block c ~block_ms:100 ~streams:[ key, "$" ] with
  | Ok [] -> ()
  | Ok _ -> Alcotest.fail "XREAD BLOCK should have timed out"
  | Error e ->
      Alcotest.failf "XREAD BLOCK: %a" C.pp_blocking_error e

(* ---------- Tests 11-14: cluster ---------- *)

let test_blpop_cross_slot_rejected () =
  if not (cluster_reachable ()) then
    skipped "cluster-bpi: BLPOP cross-slot rejected"
  else
    with_cluster_client ~pool:(pool_on ())
    @@ fun _env _clock c ->
    match
      C.blpop c ~keys:[ "{a}x"; "{b}y" ] ~block_seconds:0.1
    with
    | Error (C.Cross_slot { command = "BLPOP"; slots }) ->
        if List.length slots < 2 then
          Alcotest.failf "expected >= 2 slots in Cross_slot, got %d"
            (List.length slots)
    | Ok _ ->
        Alcotest.fail "expected Cross_slot, got Ok"
    | Error e ->
        Alcotest.failf "expected Cross_slot, got %a"
          C.pp_blocking_error e

let test_blpop_same_hashtag_allowed () =
  if not (cluster_reachable ()) then
    skipped "cluster-bpi: BLPOP same-hashtag allowed"
  else
    with_cluster_client ~pool:(pool_on ())
    @@ fun _env _clock c ->
    let keys = [ "{tag}a"; "{tag}b" ] in
    (match C.blpop c ~keys ~block_seconds:0.1 with
     | Ok None -> ()
     | Ok (Some _) ->
         Alcotest.fail "expected timeout on empty same-hashtag keys"
     | Error e ->
         Alcotest.failf "BLPOP same-hashtag: %a"
           C.pp_blocking_error e);
    List.iter
      (fun k -> let _ = C.del c [ k ] in ())
      keys

let test_xread_cross_slot_rejected () =
  if not (cluster_reachable ()) then
    skipped "cluster-bpi: XREAD BLOCK cross-slot rejected"
  else
    with_cluster_client ~pool:(pool_on ())
    @@ fun _env _clock c ->
    match
      C.xread_block c ~block_ms:100
        ~streams:[ "{a}s", "$"; "{b}s", "$" ]
    with
    | Error (C.Cross_slot { command = "XREAD BLOCK"; slots }) ->
        if List.length slots < 2 then
          Alcotest.failf "expected >= 2 slots, got %d"
            (List.length slots)
    | Ok _ -> Alcotest.fail "expected Cross_slot"
    | Error e ->
        Alcotest.failf "expected Cross_slot, got %a"
          C.pp_blocking_error e

let test_cluster_blpop_data_ready () =
  if not (cluster_reachable ()) then
    skipped "cluster-bpi: BLPOP data-ready (cluster)"
  else
    with_cluster_client ~pool:(pool_on ())
    @@ fun _env _clock c ->
    let key = "{bpi-cl}:bpi:blpop" in
    let _ = C.del c [ key ] in
    ignore (C.rpush c key [ "v1" ]);
    (match C.blpop c ~keys:[ key ] ~block_seconds:0.5 with
     | Ok (Some (k, v)) when k = key && v = "v1" -> ()
     | Ok other ->
         Alcotest.failf "BLPOP: %s"
           (match other with
            | Some (k, v) -> Printf.sprintf "Some (%S, %S)" k v
            | None -> "None")
     | Error e ->
         Alcotest.failf "BLPOP cluster: %a" C.pp_blocking_error e);
    let _ = C.del c [ key ] in
    ()

(* ---------- Test 15: real-failover via CLUSTER FAILOVER FORCE ----
   Complements test 6 (synthetic [drain_node]) with the live-failover
   path. Covers the ROADMAP "confirmed under a live failover" clause.

   Failover in Valkey cluster keeps both nodes in [CLUSTER SHARDS]
   with their node_ids intact; only the slot-ownership moves. The
   pool keys buckets by node_id, so [on_node_removed] /
   [on_node_refreshed] do NOT fire for a plain role-swap — the old
   master's bucket just stops seeing new borrows. The test-worthy
   behaviour is therefore routing correctness:

     1. Warm the pool with a lease against the current primary
        (old master), producing a live bucket.
     2. Force a failover on that shard (replica promoted → new
        master owns the slot).
     3. Exercise the blocking path again. The first blpop should
        either (a) succeed against the new primary (the router has
        refreshed and the pool opened a fresh bucket keyed by the
        new master's node_id), or (b) surface a typed
        [Exec (Server_error MOVED)] that the caller can retry. No
        hang, no untyped exception, no leaked in-use lease. *)

let force_failover_for_slot env ~slot =
  match Test_support.Cluster_nodes.replica_of_slot_owner env ~slot with
  | None ->
      Alcotest.failf
        "no replica found for shard owning slot %d" slot
  | Some (fo_host, fo_port) ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let conn =
        Valkey.Connection.connect
          ~sw ~net ~clock
          ~config:Valkey.Connection.Config.default
          ~host:fo_host ~port:fo_port ()
      in
      let _ =
        Valkey.Connection.request
          conn [| "CLUSTER"; "FAILOVER"; "FORCE" |]
      in
      Valkey.Connection.close conn

let with_cluster_client_refresh ?(pool = BP.Config.default)
    ~refresh_interval f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let pool_ref = ref None in
  let cr_config = {
    (Valkey.Cluster_router.Config.default ~seeds) with
    topology_hooks = C.topology_hooks_for_pool_ref pool_ref;
    refresh_interval;
  } in
  let router =
    match
      Valkey.Cluster_router.create ~sw ~net ~clock ~config:cr_config ()
    with
    | Ok r -> r
    | Error s -> Alcotest.failf "cluster_router: %s" s
  in
  let client_config = { C.Config.default with blocking_pool = pool } in
  let c =
    C.from_router ~sw ~net ~clock ~config:client_config router
  in
  pool_ref := C.For_testing.blocking_pool c;
  let r =
    try f env clock c
    with e -> C.close c; raise e
  in
  C.close c;
  r

let test_node_gone_after_real_failover () =
  if not (cluster_reachable ()) then
    skipped "cluster-bpi: real-failover drain"
  else
    with_cluster_client_refresh
      ~pool:(pool_on ~max_per_node:2 ~borrow_timeout:(Some 1.0) ())
      ~refresh_interval:1.0
    @@ fun env clock c ->
    let key = "{bpi-fo}:bpi:failover" in
    let slot = Valkey.Slot.of_key key in
    let _ = C.del c [ key ] in
    (* Warm the pool with one lease against the current primary,
       bounded by a client-side timeout so a slow handshake
       cannot hang the test. *)
    (match
       Eio.Time.with_timeout clock 2.0 (fun () ->
         Ok (C.blpop c ~keys:[ key ] ~block_seconds:0.05))
     with
     | Ok _ | Error `Timeout -> ());
    let pre =
      match C.For_testing.blocking_pool c with
      | None -> Alcotest.fail "blocking_pool should be Some _"
      | Some pool -> BP.stats pool
    in
    force_failover_for_slot env ~slot;
    (* Drive a non-blocking GET in a loop to force a MOVED →
       router topology refresh, then poll [blpop] on the new
       primary's bucket. The whole post-failover window is
       client-side bounded; any hang is a hard failure. *)
    let deadline = Eio.Time.now clock +. 10.0 in
    let rec settle () =
      if Eio.Time.now clock >= deadline then
        Alcotest.fail
          "post-failover blpop never succeeded within 10s; the \
           pool never routed to the new primary"
      else begin
        let _ = C.exec ~timeout:0.5 c [| "GET"; key |] in
        match
          Eio.Time.with_timeout clock 1.5 (fun () ->
            Ok (C.blpop c ~keys:[ key ] ~block_seconds:0.05))
        with
        | Ok (Ok _) -> ()  (* routed cleanly *)
        | Ok (Error (C.Exec _)) ->
            (* MOVED or transient transport — retry after a tick. *)
            Eio.Time.sleep clock 0.3; settle ()
        | Ok (Error e) ->
            Alcotest.failf
              "post-failover blpop: unexpected typed error %a"
              C.pp_blocking_error e
        | Error `Timeout ->
            Eio.Time.sleep clock 0.3; settle ()
      end
    in
    settle ();
    (* Final invariants: no leaked lease, the pool [total_created]
       must have moved at least once — either the old bucket
       picked up a retry conn, or a fresh bucket for the new
       primary was opened. *)
    (match C.For_testing.blocking_pool c with
     | None -> Alcotest.fail "blocking_pool should be Some _"
     | Some pool ->
         let post = BP.stats pool in
         if post.in_use <> 0 then
           Alcotest.failf
             "expected in_use = 0 after settle, got %d" post.in_use;
         if post.total_created <= pre.total_created then
           Alcotest.failf
             "expected total_created to grow after failover; \
              pre=%d post=%d"
             pre.total_created post.total_created);
    let _ = C.del c [ key ] in
    ()

let tests =
  [ "BLPOP data-ready via pool", `Quick, test_blpop_data_ready;
    "BLPOP timeout clean return + stats",
      `Quick, test_blpop_timeout_clean_return;
    "Pool_not_configured surfaces", `Quick, test_pool_not_configured;
    "Pool_exhausted under Fail_fast",
      `Quick, test_pool_exhausted_fail_fast;
    "Borrow_timeout under Block",
      `Quick, test_borrow_timeout_block;
    "Node_gone after drain_node",
      `Quick, test_node_gone_after_drain;
    "Exec error (WRONGTYPE) closes the leased conn",
      `Quick, test_exec_error_closes_conn;
    "WAIT returns Wait_needs_dedicated_conn",
      `Quick, test_wait_needs_dedicated;
    "wait_replicas_on via with_dedicated_conn succeeds",
      `Quick, test_wait_via_dedicated;
    "xread_block single-stream via pool",
      `Quick, test_xread_block_single_stream;
    "cluster BLPOP cross-slot rejected",
      `Slow, test_blpop_cross_slot_rejected;
    "cluster BLPOP same-hashtag multi-key allowed",
      `Slow, test_blpop_same_hashtag_allowed;
    "cluster xread_block cross-slot rejected",
      `Slow, test_xread_cross_slot_rejected;
    "cluster BLPOP data-ready",
      `Slow, test_cluster_blpop_data_ready;
    "cluster Node_gone / refreshed after CLUSTER FAILOVER FORCE",
      `Slow, test_node_gone_after_real_failover;
  ]
