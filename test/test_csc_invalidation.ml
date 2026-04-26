(** B2.4: read-path caching + server invalidation integration.

    Needs live Valkey >= 7.4 on [localhost:6379]. The cache-enabled
    client subscribes to CLIENT TRACKING (B1), fills its cache on
    GET (this step), and an invalidator fiber (B2.2) drains the
    server's invalidation pushes to evict entries. This file
    verifies the full wire round-trip end-to-end. *)

module C = Valkey.Client
module Cfg = Valkey.Client.Config
module Cache = Valkey.Cache
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let host = "localhost"
let port = 6379

(* Push delivery is async between server and client; 50ms is
   generous on loopback and stable on CI. *)
let grace_s = 0.05

let sleep_ms env ms =
  Eio.Time.sleep (Eio.Stdenv.clock env) (ms /. 1000.0)

(* Cache-enabled client [client] + bare aux client [aux] for
   "other-actor" writes. [keys] are cleaned before the body runs
   and on exit. *)
let with_csc ~keys f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let cache = Cache.create ~byte_budget:(1024 * 1024) in
  let ccfg = Valkey.Client_cache.make ~cache () in
  let client =
    C.connect ~sw ~net ~clock
      ~config:{ Cfg.default with client_cache = Some ccfg }
      ~host ~port ()
  in
  let aux = C.connect ~sw ~net ~clock ~host ~port () in
  let cleanup () = List.iter (fun k -> let _ = C.del aux [k] in ()) keys in
  cleanup ();
  let finally () = cleanup (); C.close client; C.close aux in
  Fun.protect ~finally (fun () -> f env client cache aux)

(* First GET on a cold cache must round-trip and populate. Second
   GET must come from cache: observable via server's keyspace_hits
   counter. *)
let test_populates_then_hits () =
  let k = "ocaml:csc:pop:k" in
  with_csc ~keys:[k] @@ fun _env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  (* Miss -> wire fetch + populate. *)
  (match C.get client k with
   | Ok (Some "v") -> ()
   | other ->
       Alcotest.failf "initial GET: expected Some v, got %s"
         (match other with
          | Ok None -> "None"
          | Ok (Some s) -> Printf.sprintf "Some %S" s
          | Error e -> Format.asprintf "Error %a" E.pp e));
  Alcotest.(check bool) "cache populated after miss" true
    (Option.is_some (Cache.get cache k));
  (* Hit -> no wire. We can't directly prove no wire from here, but
     we prove the cache's internal state is consistent. *)
  match C.get client k with
  | Ok (Some "v") -> ()
  | _ -> Alcotest.fail "cached GET should return v"

(* External write triggers server invalidation push; our fiber
   drains it; our cache is evicted within the grace window. *)
let test_external_set_evicts_cache () =
  let k = "ocaml:csc:ext:k" in
  with_csc ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v1" |] in
  let _ = C.get client k in
  Alcotest.(check bool) "cache has k after GET" true
    (Option.is_some (Cache.get cache k));
  let _ = C.exec aux [| "SET"; k; "v2" |] in
  sleep_ms env (grace_s *. 1000.0);
  Alcotest.(check (option reject)) "cache evicted after external SET"
    None (Cache.get cache k)

(* External DEL triggers the same invalidation path. *)
let test_external_del_evicts_cache () =
  let k = "ocaml:csc:del:k" in
  with_csc ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  let _ = C.get client k in
  Alcotest.(check bool) "cached" true
    (Option.is_some (Cache.get cache k));
  let _ = C.exec aux [| "DEL"; k |] in
  sleep_ms env (grace_s *. 1000.0);
  Alcotest.(check (option reject)) "evicted after DEL"
    None (Cache.get cache k)

(* FLUSHDB sends a null-body invalidation push; whole cache must
   clear, not just one entry. *)
let test_flushdb_clears_whole_cache () =
  let k1 = "ocaml:csc:flush:a" in
  let k2 = "ocaml:csc:flush:b" in
  with_csc ~keys:[k1; k2] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k1; "1" |] in
  let _ = C.exec aux [| "SET"; k2; "2" |] in
  let _ = C.get client k1 in
  let _ = C.get client k2 in
  Alcotest.(check int) "two entries cached" 2 (Cache.count cache);
  let _ = C.exec aux [| "FLUSHDB" |] in
  sleep_ms env (grace_s *. 1000.0);
  Alcotest.(check int) "cache fully cleared after FLUSHDB"
    0 (Cache.count cache)

(* Parse keyspace_hits out of an INFO stats reply. *)
let parse_keyspace_hits = function
  | R.Bulk_string s
  | R.Simple_string s
  | R.Verbatim_string { data = s; _ } ->
      (try
         let re = Str.regexp "keyspace_hits:\\([0-9]+\\)" in
         let _ = Str.search_forward re s 0 in
         int_of_string (Str.matched_group 1 s)
       with Not_found -> 0)
  | _ -> 0

let keyspace_hits aux =
  match C.exec aux [| "INFO"; "stats" |] with
  | Ok v -> parse_keyspace_hits v
  | Error e -> Alcotest.failf "INFO: %a" E.pp e

(* Two concurrent GETs for the same cold key must produce exactly
   one wire fetch (single-flight). Measured via the server's
   keyspace_hits counter before/after. *)
let test_single_flight_concurrent_cold_gets () =
  let k = "ocaml:csc:sflight:k" in
  with_csc ~keys:[k] @@ fun _env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  (* Reset stats for a clean measurement. *)
  let _ = C.exec aux [| "CONFIG"; "RESETSTAT" |] in
  let h0 = keyspace_hits aux in
  (* Two fibers, both GET from a cold cache. *)
  let v1 = ref None in
  let v2 = ref None in
  Eio.Fiber.both
    (fun () -> v1 := Some (C.get client k))
    (fun () -> v2 := Some (C.get client k));
  let h1 = keyspace_hits aux in
  Alcotest.(check int) "one wire fetch for two concurrent cold GETs"
    1 (h1 - h0);
  (match !v1, !v2 with
   | Some (Ok (Some "v")), Some (Ok (Some "v")) -> ()
   | _ ->
       Alcotest.fail
         "both concurrent GETs should return Ok (Some v)");
  Alcotest.(check bool) "cache populated after single-flight" true
    (Option.is_some (Cache.get cache k))

(* 10 concurrent GETs — stress version of the above, also
   confirms join-count doesn't break above 2 fibers. *)
let test_single_flight_burst () =
  let k = "ocaml:csc:sflight:burst" in
  with_csc ~keys:[k] @@ fun _env client _cache aux ->
  let _ = C.exec aux [| "SET"; k; "v" |] in
  let _ = C.exec aux [| "CONFIG"; "RESETSTAT" |] in
  let h0 = keyspace_hits aux in
  let results = Array.make 10 None in
  Eio.Fiber.all
    (List.init 10 (fun i () ->
         results.(i) <- Some (C.get client k)));
  let h1 = keyspace_hits aux in
  Alcotest.(check int) "one wire fetch for 10 concurrent cold GETs"
    1 (h1 - h0);
  Array.iter
    (function
      | Some (Ok (Some "v")) -> ()
      | _ ->
          Alcotest.fail "every fiber should see Ok (Some v)")
    results

(* --- metrics surface --------------------------------------- *)

(* Client.cache_metrics returns None when no cache is configured
   and Some m when it is. A mix of hits and misses + invalidations
   is reflected in the counters. We take a baseline and measure
   deltas; can't reset through the Client API (cache module has
   reset_metrics but we don't expose a Client.reset_cache_metrics
   — intentionally, since you usually want monotonic counters in
   production). *)
let test_cache_metrics_tracks_activity () =
  let k1 = "ocaml:csc:metrics:k1" in
  let k2 = "ocaml:csc:metrics:k2" in
  with_csc ~keys:[k1; k2] @@ fun env client _cache aux ->
  let _ = C.exec aux [| "SET"; k1; "v1" |] in
  let _ = C.exec aux [| "SET"; k2; "v2" |] in
  let baseline =
    match C.cache_metrics client with
    | Some m -> m
    | None -> Alcotest.fail "cache_metrics None with cache configured"
  in
  let _ = C.get client k1 in   (* miss, put *)
  let _ = C.get client k1 in   (* hit *)
  let _ = C.get client k2 in   (* miss, put *)
  let _ = C.get client k2 in   (* hit *)
  let _ = C.exec aux [| "SET"; k1; "v1b" |] in
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
  let m = Option.get (C.cache_metrics client) in
  Alcotest.(check int) "hits delta" 2 (m.hits - baseline.hits);
  Alcotest.(check int) "misses delta" 2 (m.misses - baseline.misses);
  Alcotest.(check bool) "invalidations increased" true
    (m.invalidations > baseline.invalidations);
  Alcotest.(check bool) "puts increased" true
    (m.puts > baseline.puts)

let tests =
  [ Alcotest.test_case "miss then hit (populate + cache-hit)" `Quick
      test_populates_then_hits;
    Alcotest.test_case "external SET evicts our cache entry" `Quick
      test_external_set_evicts_cache;
    Alcotest.test_case "external DEL evicts our cache entry" `Quick
      test_external_del_evicts_cache;
    Alcotest.test_case "FLUSHDB clears whole cache" `Quick
      test_flushdb_clears_whole_cache;
    Alcotest.test_case "single-flight: 2 concurrent cold GETs → 1 wire"
      `Quick test_single_flight_concurrent_cold_gets;
    Alcotest.test_case "single-flight: 10 concurrent cold GETs → 1 wire"
      `Quick test_single_flight_burst;
    Alcotest.test_case "cache_metrics tracks client activity" `Quick
      test_cache_metrics_tracks_activity;
  ]
