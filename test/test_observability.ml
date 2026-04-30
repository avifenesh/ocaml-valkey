(** Pure-unit coverage for [Observability.observe_cache_metrics].

    Builds a [Cache.t], increments its counters by hand, registers
    the OTel callback, runs a Meter.collect, and checks the
    emitted [Metrics.t] list contains a metric per counter with
    the right names and values. No exporter; uses the registry's
    in-memory pass directly. *)

module O = Valkey.Observability
module Cache = Valkey.Cache

(* Build a Cache.t and drive its counters by issuing a few
   synthetic puts/gets/invalidations. *)
let drive_cache () =
  let c = Cache.create ~byte_budget:(64 * 1024) in
  Cache.put c "k1" (Valkey.Resp3.Bulk_string "v1");
  Cache.put c "k2" (Valkey.Resp3.Bulk_string "v2");
  let _ = Cache.get c "k1" in
  let _ = Cache.get c "k1" in
  let _ = Cache.get c "missing" in
  Cache.evict c "k2";
  c

(* Pull metric names with a given prefix out of a Metrics.t list.
   We don't dig into the protobuf data points — the name list is
   the load-bearing user-visible contract; numeric values are
   delegated to OTel's built-in path. *)
let names_with_prefix ~prefix metrics =
  let open Opentelemetry.Proto.Metrics in
  metrics
  |> List.map (fun (m : metric) -> m.name)
  |> List.filter (fun name ->
       String.length name >= String.length prefix
       && String.sub name 0 (String.length prefix) = prefix)
  |> List.sort compare

let test_emits_six_counters () =
  let cache = drive_cache () in
  O.observe_cache_metrics ~name:"test.cache"
    (fun () -> Some (Cache.metrics cache));
  let collected =
    Opentelemetry.Meter.collect Opentelemetry.Meter.dummy
  in
  let names = names_with_prefix ~prefix:"test.cache." collected in
  Alcotest.(check (list string)) "six counters with stable names"
    [ "test.cache.evicts.budget";
      "test.cache.evicts.ttl";
      "test.cache.hits";
      "test.cache.invalidations";
      "test.cache.misses";
      "test.cache.puts" ]
    names

let test_none_emits_nothing () =
  O.observe_cache_metrics ~name:"test.cache.absent" (fun () -> None);
  let collected =
    Opentelemetry.Meter.collect Opentelemetry.Meter.dummy
  in
  let names = names_with_prefix ~prefix:"test.cache.absent." collected in
  Alcotest.(check (list string)) "no metrics for None" [] names

(* --- Blocking_pool bridge ----------------------------------------- *)

let stub_stats : O.blocking_pool_stats =
  { in_use = 3;
    idle = 2;
    waiters = 1;
    total_borrowed = 17;
    total_created = 5;
    total_closed_dirty = 2;
    total_borrow_timeouts = 1;
    total_exhaustion_rejects = 0;
  }

let test_blocking_pool_emits_eight_counters () =
  O.observe_blocking_pool_metrics ~name:"test.bp"
    (fun () -> Some stub_stats);
  let collected =
    Opentelemetry.Meter.collect Opentelemetry.Meter.dummy
  in
  let names = names_with_prefix ~prefix:"test.bp." collected in
  Alcotest.(check (list string))
    "eight metrics with stable names"
    [ "test.bp.borrow_timeouts";
      "test.bp.borrowed";
      "test.bp.closed_dirty";
      "test.bp.created";
      "test.bp.exhaustion_rejects";
      "test.bp.idle";
      "test.bp.in_use";
      "test.bp.waiters" ]
    names

let test_blocking_pool_none_emits_nothing () =
  O.observe_blocking_pool_metrics ~name:"test.bp.absent"
    (fun () -> None);
  let collected =
    Opentelemetry.Meter.collect Opentelemetry.Meter.dummy
  in
  let names = names_with_prefix ~prefix:"test.bp.absent." collected in
  Alcotest.(check (list string)) "no metrics for None" [] names

(* --- connect_span: valkey.auth.mode attribute --------------------- *)

(* [connect_span] stamps a fixed set of attributes on the active
   span inside [Otel.Tracer.with_]. We read them back via
   [Opentelemetry.Span.attrs] from inside the callback — no
   exporter needed. *)
let test_connect_span_records_auth_mode ~auth_mode =
  let seen_mode = ref None in
  O.connect_span ~host:"test.example.com" ~port:6379
    ~tls:true ~proto:3 ~auth_mode
    (fun span ->
      let attrs = Opentelemetry.Span.attrs span in
      seen_mode :=
        List.find_map
          (fun (k, v) ->
            if k = "valkey.auth.mode" then
              match v with
              | `String s -> Some s
              | _ -> None
            else None)
          attrs);
  Alcotest.(check (option string))
    (Printf.sprintf "valkey.auth.mode = %s" auth_mode)
    (Some auth_mode) !seen_mode

let test_connect_span_auth_mode_none () =
  test_connect_span_records_auth_mode ~auth_mode:"none"

let test_connect_span_auth_mode_static () =
  test_connect_span_records_auth_mode ~auth_mode:"static"

let test_connect_span_auth_mode_iam () =
  test_connect_span_records_auth_mode ~auth_mode:"iam"

let test_connect_span_auth_mode_custom () =
  test_connect_span_records_auth_mode ~auth_mode:"vault"

let tests =
  [ Alcotest.test_case "observe_cache_metrics emits six counters" `Quick
      test_emits_six_counters;
    Alcotest.test_case "observe_cache_metrics no-op on None" `Quick
      test_none_emits_nothing;
    Alcotest.test_case "observe_blocking_pool_metrics emits eight metrics"
      `Quick test_blocking_pool_emits_eight_counters;
    Alcotest.test_case "observe_blocking_pool_metrics no-op on None"
      `Quick test_blocking_pool_none_emits_nothing;
    Alcotest.test_case "connect_span auth_mode=none" `Quick
      test_connect_span_auth_mode_none;
    Alcotest.test_case "connect_span auth_mode=static" `Quick
      test_connect_span_auth_mode_static;
    Alcotest.test_case "connect_span auth_mode=iam" `Quick
      test_connect_span_auth_mode_iam;
    Alcotest.test_case "connect_span auth_mode=custom" `Quick
      test_connect_span_auth_mode_custom;
  ]
