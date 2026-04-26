(** Integration tests for client-side caching.

    These tests are the behavioural contract we commit to before a
    single line of Branch-B implementation lands. Each step in the
    plan (B1..B9) turns some of these from red to green. They assume
    a live Valkey >= 7.4 on [localhost:6379].

    Conventions:
    - Each test uses its own key namespace (e.g. "ocaml:csc:hit:*")
      to keep tests independent. Tests clean up their keys on exit.
    - [with_csc_client] opens a client with a fresh cache config; the
      inner body gets [client], [cache], [aux] where [aux] is a
      second bare client used to poke the server from "outside"
      (simulating another actor writing the key).
    - Tests use small sleeps around invalidation events because push
      delivery is asynchronous. A 50 ms grace is generous for a local
      Valkey and stable in CI.

    Many of these tests reference APIs that do not yet exist
    ([Client.Config.client_cache], [Client.cache_metrics], etc.).
    That is intentional — the tests *drive* the API design. They are
    expected to fail to compile until Branch B lands the surface.
*)

module C = Valkey.Client
module Cfg = Valkey.Client.Config
module Conn = Valkey.Connection
module E = Valkey.Connection.Error
module R = Valkey.Resp3
module Cache = Valkey.Cache

let host = "localhost"
let port = 6379

(* --- harness helpers --------------------------------------------- *)

(* Small grace period for push delivery in the asynchronous path.
   Tuned generously — a local Valkey delivers in sub-ms. *)
let invalidation_grace_s = 0.05

let sleep_ms env ms = Eio.Time.sleep (Eio.Stdenv.clock env) (ms /. 1000.0)

(* Plain client, no cache — used as the "other actor" that writes
   keys to trigger invalidations. *)
let make_bare_client ~sw ~net ~clock =
  C.connect ~sw ~net ~clock ~host ~port ()

(* Cache-enabled client. The API does not yet exist; this is the
   shape Branch B commits to. *)
let make_cache_client ~sw ~net ~clock ?(byte_budget = 1024 * 1024)
    ?(entry_ttl_ms = None) () =
  let cache = Cache.create ~byte_budget in
  let connection =
    (* Client.Config.t has a [connection : Connection.Config.t]; that
       Connection.Config.t is where the cache config lives. B1 adds a
       [client_cache] field there carrying the [Cache.t] plus mode
       knobs. *)
    { Conn.Config.default with
      client_cache =
        Some { cache;
               mode = `Default;       (* per-client (non-broadcast) *)
               optin = true;          (* OPTIN + CLIENT CACHING YES *)
               noloop = false;        (* trust server echoes *)
               entry_ttl_ms;          (* safety-net TTL, off by default *)
             } }
  in
  let cfg = { Cfg.default with connection } in
  let c = C.connect ~sw ~net ~clock ~config:cfg ~host ~port () in
  c, cache

let cleanup_keys client keys =
  List.iter (fun k -> let _ = C.del client [k] in ()) keys

(* Wrap a test body. Opens one cache-enabled client and one bare
   client, passes both to the body, then closes both and cleans up
   the supplied key list. *)
let with_csc_client ?byte_budget ?entry_ttl_ms ~keys f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client, cache =
    make_cache_client ~sw ~net ~clock ?byte_budget ?entry_ttl_ms ()
  in
  let aux = make_bare_client ~sw ~net ~clock in
  cleanup_keys aux keys;
  let finally () =
    cleanup_keys aux keys;
    C.close client;
    C.close aux
  in
  Fun.protect ~finally (fun () -> f env client cache aux)

(* --- B1: TRACKING is issued on connect --------------------------- *)

(* After connect, [CLIENT TRACKINGINFO] on our connection should
   report [flags: on] and [redirect: -1]. Using the raw
   connection to issue the admin command — this is the most direct
   check that B1 ran CLIENT TRACKING ON OPTIN. *)
let test_tracking_enabled_on_connect () =
  with_csc_client ~keys:[] @@ fun _env client _cache _aux ->
  match C.exec client [| "CLIENT"; "TRACKINGINFO" |] with
  | Ok (R.Map kvs) ->
      let find k =
        List.find_map
          (fun (kk, vv) ->
            match kk with
            | R.Bulk_string s when s = k -> Some vv
            | _ -> None)
          kvs
      in
      (match find "flags" with
       | Some (R.Array flags) ->
           let flag_names =
             List.filter_map
               (function R.Bulk_string s -> Some s | _ -> None)
               flags
           in
           if not (List.mem "on" flag_names) then
             Alcotest.failf
               "expected 'on' in TRACKINGINFO flags, got [%s]"
               (String.concat ", " flag_names);
           if not (List.mem "optin" flag_names) then
             Alcotest.failf
               "expected 'optin' in TRACKINGINFO flags, got [%s]"
               (String.concat ", " flag_names)
       | _ -> Alcotest.fail "TRACKINGINFO flags missing or wrong type")
  | Ok other ->
      Alcotest.failf "expected Map reply, got %a" R.pp other
  | Error e -> Alcotest.failf "TRACKINGINFO: %a" E.pp e

(* On reconnect, the server forgets per-client tracking state. The
   client must re-issue CLIENT TRACKING after every reconnect. We
   simulate the server-side disconnect via CLIENT KILL ID <self-id>
   issued from aux, wait for the reconnect, then check TRACKINGINFO
   is still [on]. *)
let test_tracking_reinstated_after_reconnect () =
  with_csc_client ~keys:[] @@ fun env client _cache aux ->
  (* Get our client id. *)
  let self_id =
    match C.exec client [| "CLIENT"; "ID" |] with
    | Ok (R.Integer id) -> id
    | _ -> Alcotest.fail "CLIENT ID failed"
  in
  (* Kill ourselves from outside. *)
  let _ = C.exec aux [| "CLIENT"; "KILL"; "ID"; Int64.to_string self_id |] in
  (* Poke the client to trigger reconnect. *)
  sleep_ms env 100.0;
  let _ = C.exec client [| "PING" |] in
  sleep_ms env 200.0;
  (* Now TRACKINGINFO on the new connection should still show tracking on. *)
  match C.exec client [| "CLIENT"; "TRACKINGINFO" |] with
  | Ok (R.Map kvs) ->
      let has_on =
        List.exists
          (fun (k, v) ->
            match k, v with
            | R.Bulk_string "flags", R.Array flags ->
                List.exists
                  (function R.Bulk_string "on" -> true | _ -> false)
                  flags
            | _ -> false)
          kvs
      in
      if not has_on then
        Alcotest.fail "tracking not reinstated after reconnect"
  | _ -> Alcotest.fail "TRACKINGINFO after reconnect failed"

(* --- B2: invalidation push drains into the cache ---------------- *)

(* Basic happy path: GET K caches, another client SETs K, we see
   the cache evict the entry within the grace period. *)
let test_invalidation_evicts_on_external_write () =
  let k = "ocaml:csc:inv:k1" in
  with_csc_client ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v1" |] in
  (* Prime the cache. *)
  (match C.get client k with
   | Ok (Some "v1") -> ()
   | _ -> Alcotest.fail "expected Some v1 on initial GET");
  Alcotest.(check bool) "cache has k1 after GET" true
    (Option.is_some (Cache.get cache k));
  (* Write from outside. Server sends us an invalidation push. *)
  let _ = C.exec aux [| "SET"; k; "v2" |] in
  sleep_ms env (invalidation_grace_s *. 1000.0);
  Alcotest.(check (option reject)) "cache evicted after external SET"
    None (Cache.get cache k)

(* FLUSHALL sends a null-body invalidation push; implementation must
   clear the whole cache, not treat null as "no keys to invalidate". *)
let test_flushall_clears_cache () =
  let k1 = "ocaml:csc:flushall:a" in
  let k2 = "ocaml:csc:flushall:b" in
  with_csc_client ~keys:[k1; k2] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k1; "1" |] in
  let _ = C.exec aux [| "SET"; k2; "2" |] in
  let _ = C.get client k1 in
  let _ = C.get client k2 in
  Alcotest.(check int) "two entries cached" 2 (Cache.count cache);
  (* Full server flush. *)
  let _ = C.exec aux [| "FLUSHDB" |] in
  sleep_ms env (invalidation_grace_s *. 1000.0);
  Alcotest.(check int) "cache fully cleared after FLUSHDB" 0 (Cache.count cache)

(* DEL is the simplest single-key invalidation path. *)
let test_del_evicts_entry () =
  let k = "ocaml:csc:del:k" in
  with_csc_client ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  let _ = C.get client k in
  Alcotest.(check bool) "cached" true (Option.is_some (Cache.get cache k));
  let _ = C.exec aux [| "DEL"; k |] in
  sleep_ms env (invalidation_grace_s *. 1000.0);
  Alcotest.(check (option reject)) "evicted after DEL" None (Cache.get cache k)

(* --- B3: race-safe GET + single-flight --------------------------- *)

(* Two concurrent GETs for the same cold key must result in exactly
   one wire round-trip. We measure by observing that the server's
   [INFO stats] keyspace_hits increments by only one. *)
let test_single_flight_dedup () =
  let k = "ocaml:csc:sflight:k" in
  with_csc_client ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  let initial_hits =
    match C.exec aux [| "INFO"; "stats" |] with
    | Ok (R.Bulk_string s) -> (
        (* Parse "keyspace_hits:N" out of INFO. *)
        try
          let re = Str.regexp "keyspace_hits:\\([0-9]+\\)" in
          let _ = Str.search_forward re s 0 in
          int_of_string (Str.matched_group 1 s)
        with Not_found -> 0)
    | _ -> 0
  in
  (* Two concurrent GETs for k, with cache empty. *)
  Eio.Fiber.both
    (fun () -> ignore (C.get client k))
    (fun () -> ignore (C.get client k));
  sleep_ms env 20.0;
  let final_hits =
    match C.exec aux [| "INFO"; "stats" |] with
    | Ok (R.Bulk_string s) -> (
        try
          let re = Str.regexp "keyspace_hits:\\([0-9]+\\)" in
          let _ = Str.search_forward re s 0 in
          int_of_string (Str.matched_group 1 s)
        with Not_found -> 0)
    | _ -> 0
  in
  Alcotest.(check int) "exactly one wire hit despite two concurrent GETs"
    1 (final_hits - initial_hits);
  (* And the cache should now hold the value. *)
  Alcotest.(check bool) "cache populated after single-flight" true
    (Option.is_some (Cache.get cache k))

(* If an invalidation arrives for K after we sent GET K but before
   the reply lands, the reply must NOT be cached. We can't control
   the timing from the test directly; we approximate by firing a
   burst of (external write → GET) pairs and assert cache state is
   consistent with server state on each iteration. Flaky signal but
   catches the egregious bugs. *)
let test_no_stale_cache_after_racing_write () =
  let k = "ocaml:csc:race:k" in
  with_csc_client ~keys:[k] @@ fun env client cache aux ->
  for i = 1 to 20 do
    let expected = string_of_int i in
    let _ = C.exec aux [| "SET"; k; expected |] in
    (* No deliberate delay — we want the race window. *)
    let observed =
      match C.get client k with
      | Ok (Some s) -> s
      | Ok None -> "<none>"
      | Error e -> Alcotest.failf "GET: %a" E.pp e
    in
    (* Must be either expected, or something newer (another
       iteration has raced past us), never older. *)
    let o = int_of_string_opt observed |> Option.value ~default:(-1) in
    if o < i then
      Alcotest.failf "stale read at iteration %d: expected >= %d, got %s"
        i i observed;
    sleep_ms env (invalidation_grace_s *. 1000.0);
    Alcotest.(check bool) "cache reflects latest write after grace" true
      (match Cache.get cache k with
       | Some (R.Bulk_string s) -> int_of_string_opt s |> Option.value ~default:0 >= i
       | _ -> true)    (* None is OK: invalidated, not yet re-fetched *)
  done

(* --- B4: local-write eviction (NOLOOP=off flavour) -------------- *)

(* With NOLOOP=off (our default), the server echoes our own writes
   back as invalidations. A SET from us should end up with k evicted
   from our own cache via the invalidator fiber path, not via a
   client-side shortcut. The invariant: after our SET, our cache
   does not contain the key. *)
let test_own_write_evicts_cache () =
  let k = "ocaml:csc:own:k" in
  with_csc_client ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "initial" |] in
  let _ = C.get client k in
  Alcotest.(check bool) "cached" true (Option.is_some (Cache.get cache k));
  (* We write the key. *)
  let _ = C.exec client [| "SET"; k; "new" |] in
  sleep_ms env (invalidation_grace_s *. 1000.0);
  Alcotest.(check (option reject)) "own write evicted our cache entry"
    None (Cache.get cache k)

(* --- B5: cluster + slot migration + reconnect-flush -------------- *)

(* The remainder require a cluster; they live in a separate file
   test_client_side_cache_cluster.ml if we decide to split. For now
   keep stubs so the shape is committed. *)

(* Reconnect flushes the cache. If the current connection dies, we
   must drop all cached entries since the server has forgotten the
   tracking context. *)
let test_reconnect_flushes_cache () =
  let k = "ocaml:csc:reconnect:k" in
  with_csc_client ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  let _ = C.get client k in
  Alcotest.(check bool) "cached" true (Option.is_some (Cache.get cache k));
  (* Force reconnect via CLIENT KILL from outside. *)
  let self_id =
    match C.exec client [| "CLIENT"; "ID" |] with
    | Ok (R.Integer id) -> id
    | _ -> Alcotest.fail "CLIENT ID failed"
  in
  let _ = C.exec aux [| "CLIENT"; "KILL"; "ID"; Int64.to_string self_id |] in
  sleep_ms env 200.0;
  let _ = C.exec client [| "PING" |] in
  sleep_ms env 100.0;
  Alcotest.(check int) "cache flushed on reconnect" 0 (Cache.count cache)

(* --- B6: TTL safety net ----------------------------------------- *)

(* Set a short TTL, write a key from outside with the server's
   invalidation silenced (simulate by... we can't actually silence
   server pushes; instead we assert that if we skip the grace
   period a just-past-TTL entry is not returned). *)
let test_ttl_safety_net_rejects_stale_entry () =
  let k = "ocaml:csc:ttl:k" in
  with_csc_client ~entry_ttl_ms:(Some 50) ~keys:[k]
  @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  (match C.get client k with
   | Ok (Some "v") -> ()
   | _ -> Alcotest.fail "initial GET");
  Alcotest.(check bool) "cached" true (Option.is_some (Cache.get cache k));
  (* Wait past TTL without any external write. *)
  sleep_ms env 150.0;
  Alcotest.(check (option reject)) "TTL-expired entry rejected"
    None (Cache.get cache k)

(* --- B7: metrics ------------------------------------------------- *)

(* After a mix of hits and misses, the OTel metrics or an exposed
   [cache_metrics] API must reflect reality. We check the exposed
   counter API — OTel export is tested separately in
   test_observability.ml (not yet written). *)
let test_metrics_count_hits_and_misses () =
  let k = "ocaml:csc:metrics:k" in
  with_csc_client ~keys:[k] @@ fun _env client _cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  let _ = C.get client k in   (* miss -> fetch *)
  let _ = C.get client k in   (* hit *)
  let _ = C.get client k in   (* hit *)
  match C.cache_metrics client with
  | Some m ->
      Alcotest.(check int) "hits" 2 m.hits;
      Alcotest.(check int) "misses" 1 m.misses
  | None -> Alcotest.fail "cache_metrics returned None with cache enabled"

(* --- registration ------------------------------------------------ *)

let tests =
  [ Alcotest.test_case "B1 tracking enabled on connect" `Quick
      test_tracking_enabled_on_connect;
    Alcotest.test_case "B1 tracking reinstated after reconnect" `Slow
      test_tracking_reinstated_after_reconnect;
    Alcotest.test_case "B2 invalidation evicts on external write" `Quick
      test_invalidation_evicts_on_external_write;
    Alcotest.test_case "B2 FLUSHDB clears entire cache" `Quick
      test_flushall_clears_cache;
    Alcotest.test_case "B2 DEL evicts entry" `Quick test_del_evicts_entry;
    Alcotest.test_case "B3 single-flight dedup for concurrent GETs" `Quick
      test_single_flight_dedup;
    Alcotest.test_case "B3 no stale cache under racing writes" `Slow
      test_no_stale_cache_after_racing_write;
    Alcotest.test_case "B4 own write evicts our cache entry" `Quick
      test_own_write_evicts_cache;
    Alcotest.test_case "B5 reconnect flushes cache" `Slow
      test_reconnect_flushes_cache;
    Alcotest.test_case "B6 TTL safety-net rejects stale entry" `Slow
      test_ttl_safety_net_rejects_stale_entry;
    Alcotest.test_case "B7 metrics count hits and misses" `Quick
      test_metrics_count_hits_and_misses;
  ]
