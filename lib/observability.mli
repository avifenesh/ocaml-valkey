(** OpenTelemetry instrumentation for valkey.

    All spans the library emits live behind these helpers — one place
    to grep for span names, attribute keys, and the redaction policy.

    See [docs/observability.md] for setup, the full attribute schema,
    and the redaction invariants this module enforces. *)

(** Wrap a connect-and-handshake (TCP + optional TLS + [HELLO] /
    [SELECT]) in a [valkey.connect] span. Attributes:
    [valkey.host], [valkey.port], [valkey.tls], [valkey.proto],
    [valkey.auth.mode].

    [host] and [port] are address metadata only; the library never
    surfaces the [HELLO]/[AUTH] credentials it sends inside the span.

    [auth_mode] is a short tag describing the auth path — ["none"],
    ["static"], ["iam"], or a user-supplied name from
    {!Connection.Auth.custom}. *)
val connect_span :
  host:string ->
  port:int ->
  tls:bool ->
  proto:int ->
  auth_mode:string ->
  (Opentelemetry.Span.t -> 'a) ->
  'a

(** Emit a span event under the active span recording an
    unsuccessful in-place [AUTH] refresh on a live connection.
    Attributes: [valkey.error.code] (the [Connection.Error.t]
    variant name). Stateless — no counter is incremented; users
    who want aggregate counts tail their exporter. *)
val record_auth_refresh_failure : Connection_error.t -> unit

(** Wrap [Discovery.discover_from_seeds] in a [valkey.cluster.discover]
    span. Records [valkey.cluster.seed_count]. The outcome
    ([agreed]/[agreed_fallback]/[no_agreement]) is added later via
    {!record_discovery_outcome}. *)
val discover_span :
  seed_count:int -> (Opentelemetry.Span.t -> 'a) -> 'a

(** Wrap one tick of the periodic topology refresh in a
    [valkey.cluster.refresh] span. *)
val refresh_span : (Opentelemetry.Span.t -> 'a) -> 'a

(** Stamp a discover/refresh outcome onto the active span. The body
    of [discover_span]/[refresh_span] should call this exactly once,
    with the variant matching the [Discovery.select] result. *)
val record_discovery_outcome :
  Opentelemetry.Span.t ->
  [< `Agreed | `Agreed_fallback | `No_agreement ] ->
  unit

(** Register a meter callback that exposes the CSC cache counters
    as OpenTelemetry cumulative monotonic sums.

    [metrics_fn] is a 0-argument closure that reads the current
    counters; the typical caller passes [(fun () -> Client.cache_metrics c)].
    Returning [None] (CSC not configured for that client) emits no
    metrics for that tick.

    Six metrics are emitted per tick, named [<name>.<counter>]:
    {ul
    {- [hits], [misses] — read accounting.}
    {- [evicts.budget] — entries pushed out by byte-budget pressure.}
    {- [evicts.ttl] — entries pushed out by TTL safety net.}
    {- [invalidations] — entries removed by server-invalidation pushes.}
    {- [puts] — total [Cache.put] calls (incl. oversize-rejects).}}

    Default [name] is ["valkey.cache"]. With no exporter
    configured the cost is the OTel registry's no-op path
    (a list-of-callbacks walk on collect, each of which is a
    cheap atomic read).

    Idempotent at the OTel layer: each call adds another
    callback. Don't call this twice for the same client unless
    you want duplicate metrics. *)
val observe_cache_metrics :
  ?name:string ->
  (unit -> Cache.metrics option) ->
  unit

(** Plain-record view of [Blocking_pool.Stats.t], declared here so
    [Observability] does not depend on [Blocking_pool] (which would
    cycle through [Connection]). Field names match
    [Blocking_pool.Stats.t] verbatim — the typical caller builds
    it with a direct record copy. *)
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

(** Register a meter callback that exposes [Blocking_pool.Stats.t]
    as OpenTelemetry metrics.

    [stats_fn] is a 0-argument closure that reads the current
    aggregate stats. The typical caller wraps
    [Blocking_pool.stats] and re-packs the record:
    {[
      let bridge pool =
        Observability.observe_blocking_pool_metrics (fun () ->
          match pool with
          | None -> None
          | Some p ->
              let s = Valkey.Blocking_pool.stats p in
              Some {
                Observability.in_use = s.in_use;
                idle = s.idle;
                waiters = s.waiters;
                total_borrowed = s.total_borrowed;
                total_created = s.total_created;
                total_closed_dirty = s.total_closed_dirty;
                total_borrow_timeouts = s.total_borrow_timeouts;
                total_exhaustion_rejects = s.total_exhaustion_rejects;
              })
    ]}
    Returning [None] (pool not configured) emits no metrics.

    Eight metrics per tick, named [<name>.<counter>]:
    {ul
    {- [in_use], [idle], [waiters] — point-in-time gauges, emitted
       as non-monotonic sums (OTel UpDownCounter).}
    {- [borrowed], [created] — cumulative monotonic counters.}
    {- [closed_dirty] — conns closed because a lease scope raised /
       was cancelled / tagged stale mid-lease. High rate signals
       cancellation pressure or topology churn.}
    {- [borrow_timeouts] — borrows that hit [borrow_timeout].}
    {- [exhaustion_rejects] — borrows rejected under
       [`Fail_fast] when every conn was in use.}}

    Default [name] is ["valkey.blocking_pool"]. Stats are aggregated
    across all node buckets — there is no per-node attribute in this
    release; wire per-node views via [Blocking_pool.stats_by_node]
    if you need them.

    Idempotent at the OTel layer: each call adds another
    callback. Don't call this twice for the same pool unless
    you want duplicate metrics. *)
val observe_blocking_pool_metrics :
  ?name:string ->
  (unit -> blocking_pool_stats option) ->
  unit
