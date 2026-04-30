(** OpenTelemetry instrumentation for valkey.

    Span and attribute names live here — one place to grep, one place
    to enforce the redaction invariants below.

    {1 Setup}

    The library only emits spans. The application configures the
    exporter (and ambient-context backend, for span propagation across
    fibers). With no exporter configured, span ops are near-no-op
    cheap.

    See [docs/observability.md] for the full setup recipe.

    {1 Redaction invariants — non-negotiable}

    Never put any of the following into span attributes or events:

    - [HELLO]/[AUTH] credentials (username, password, token).
    - Command keys or values (the operator's data).
    - Server error message bodies (only the [code] field is public).

    Generic values (host, port, slot number, command verb, error code)
    are fair game.
*)

module Otel = Opentelemetry

(** Span guard for [Connection.connect_and_handshake]. Records the
    bounded operation of opening a TCP socket, optionally upgrading
    to TLS, and running the [HELLO] / [SELECT] handshake. *)
let connect_span ~host ~port ~tls ~proto ~auth_mode cb =
  Otel.Tracer.with_
    ~kind:Otel.Span.Span_kind_client
    ~attrs:
      [
        "valkey.host", `String host;
        "valkey.port", `Int port;
        "valkey.tls", `Bool tls;
        "valkey.proto", `Int proto;
        "valkey.auth.mode", `String auth_mode;
      ]
    "valkey.connect" cb

(** Short name for each [Connection_error.t] variant — stable
    identifier for span attributes; never includes the error
    payload (which may contain server-provided data). *)
let error_code_name : Connection_error.t -> string = function
  | Tcp_refused _ -> "tcp_refused"
  | Dns_failed _ -> "dns_failed"
  | Tls_failed _ -> "tls_failed"
  | Handshake_rejected _ -> "handshake_rejected"
  | Auth_failed _ -> "auth_failed"
  | Protocol_violation _ -> "protocol_violation"
  | Timeout -> "timeout"
  | Interrupted -> "interrupted"
  | Queue_full -> "queue_full"
  | Circuit_open -> "circuit_open"
  | Closed -> "closed"
  | Server_error _ -> "server_error"
  | Terminal _ -> "terminal"

(** Emit a span event for a refresh-AUTH failure. No state
    mutation; the event attaches to the currently-active
    [Ambient_span] (or is a no-op if nothing is active),
    following the same pattern as [record_discovery_outcome]. *)
let record_auth_refresh_failure err =
  match Otel.Ambient_span.get () with
  | None -> ()
  | Some span ->
      let event =
        Otel.Event.make
          ~attrs:
            [ "valkey.error.code",
              `String (error_code_name err) ]
          "valkey.iam.auth_refresh_failure"
      in
      Otel.Span.add_event span event

(** Span guard for [Discovery.discover_from_seeds]. *)
let discover_span ~seed_count cb =
  Otel.Tracer.with_
    ~attrs:[ "valkey.cluster.seed_count", `Int seed_count ]
    "valkey.cluster.discover" cb

(** Span guard for the periodic topology refresh. *)
let refresh_span cb =
  Otel.Tracer.with_ "valkey.cluster.refresh" cb

(** Tag a discover/refresh outcome onto the active span. Keep the
    surface tiny — three outcomes, never the topology itself. *)
let record_discovery_outcome span outcome =
  let v =
    match outcome with
    | `Agreed -> "agreed"
    | `Agreed_fallback -> "agreed_fallback"
    | `No_agreement -> "no_agreement"
  in
  Otel.Span.add_attrs span [ "valkey.cluster.outcome", `String v ]

(** Bridge [Cache.metrics] counters to OpenTelemetry as cumulative
    monotonic sums. Each counter (hits, misses, evicts.budget,
    evicts.ttl, invalidations, puts) becomes a metric named
    [<prefix>.<counter>] (default prefix [valkey.cache]). The
    callback runs at every meter collect; with no exporter
    configured, the cost is the OTel registry's no-op path.
    No-op when [metrics_fn] returns [None] (CSC not configured). *)
let observe_cache_metrics ?(name = "valkey.cache")
    (metrics_fn : unit -> Cache.metrics option) =
  let start_ns = Otel.Clock.now_main () in
  Otel.Meter.add_cb (fun ~clock:_ () ->
      match metrics_fn () with
      | None -> []
      | Some (m : Cache.metrics) ->
          let now = Otel.Clock.now_main () in
          let mk suffix v =
            Otel.Metrics.sum
              ~name:(name ^ "." ^ suffix)
              ~is_monotonic:true
              [ Otel.Metrics.int ~start_time_unix_nano:start_ns ~now v ]
          in
          [ mk "hits" m.hits;
            mk "misses" m.misses;
            mk "evicts.budget" m.evicts_budget;
            mk "evicts.ttl" m.evicts_ttl;
            mk "invalidations" m.invalidations;
            mk "puts" m.puts ])

(** Plain-record view of [Blocking_pool.Stats.t] — declared locally
    to keep [Observability] free of a [Blocking_pool] dependency
    (which would cycle through [Connection]). *)
type blocking_pool_stats = {
  in_use : int;
  idle : int;
  waiters : int;
  total_borrowed : int;
  total_created : int;
  total_closed_dirty : int;
  total_borrow_timeouts : int;
  total_exhaustion_rejects : int;
}

(** Bridge blocking-pool stats to OpenTelemetry. [in_use], [idle],
    and [waiters] are point-in-time gauges (UpDownCounter idiom —
    [sum ~is_monotonic:false]); the five [total_*] counters are
    cumulative monotonic sums. Aggregate across all node buckets in
    this release. *)
let observe_blocking_pool_metrics ?(name = "valkey.blocking_pool")
    (stats_fn : unit -> blocking_pool_stats option) =
  let start_ns = Otel.Clock.now_main () in
  Otel.Meter.add_cb (fun ~clock:_ () ->
      match stats_fn () with
      | None -> []
      | Some s ->
          let now = Otel.Clock.now_main () in
          let mk ~monotonic suffix v =
            Otel.Metrics.sum
              ~name:(name ^ "." ^ suffix)
              ~is_monotonic:monotonic
              [ Otel.Metrics.int ~start_time_unix_nano:start_ns ~now v ]
          in
          [ mk ~monotonic:false "in_use" s.in_use;
            mk ~monotonic:false "idle" s.idle;
            mk ~monotonic:false "waiters" s.waiters;
            mk ~monotonic:true "borrowed" s.total_borrowed;
            mk ~monotonic:true "created" s.total_created;
            mk ~monotonic:true "closed_dirty" s.total_closed_dirty;
            mk ~monotonic:true "borrow_timeouts" s.total_borrow_timeouts;
            mk ~monotonic:true "exhaustion_rejects"
              s.total_exhaustion_rejects ])
