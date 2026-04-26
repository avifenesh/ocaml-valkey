(** OpenTelemetry instrumentation for valkey.

    All spans the library emits live behind these helpers — one place
    to grep for span names, attribute keys, and the redaction policy.

    See [docs/observability.md] for setup, the full attribute schema,
    and the redaction invariants this module enforces. *)

(** Wrap a connect-and-handshake (TCP + optional TLS + [HELLO] /
    [SELECT]) in a [valkey.connect] span. Attributes:
    [valkey.host], [valkey.port], [valkey.tls], [valkey.proto].

    [host] and [port] are address metadata only; the library never
    surfaces the [HELLO]/[AUTH] credentials it sends inside the span. *)
val connect_span :
  host:string ->
  port:int ->
  tls:bool ->
  proto:int ->
  (Opentelemetry.Span.t -> 'a) ->
  'a

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
