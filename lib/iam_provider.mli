(** Stateful AWS ElastiCache IAM auth provider.

    Wraps {!Iam_sigv4.presigned_elasticache_token} with a
    cached token and a periodic refresh fiber. On each tick
    ({!Config.refresh_interval}, default 600s = 10 min) the
    provider:

    - signs a fresh token with the current wall-clock,
    - publishes it atomically to the cache,
    - calls {!Connection.refresh_auth} on every registered
      live connection so the server sees the new token before
      the old one expires (server-side TTL is 15 minutes).

    AWS tokens have a 15-minute TTL and the server tolerates
    ±5 minutes of clock skew, giving 10 minutes as the correct
    refresh cadence: well within TTL, well past the skew
    window. The 12-hour server-side auto-disconnect is
    orthogonal — when it fires, the Connection's reconnect
    supervisor re-handshakes, which calls this provider's
    [auth_provider] closure and gets the cached token.

    If the in-place [AUTH] refresh fails on a connection, that
    connection is {!Connection.interrupt}ed by
    {!Connection.refresh_auth} — the supervisor re-handshakes,
    calls this provider again, and comes back up on a fresh
    token. That is the only recovery path; there is no
    backoff-and-retry at this layer. *)

module Config : sig
  type t = {
    refresh_interval : float;
      (** Seconds between automatic re-sign + push-AUTH. Default
          [600.0] (10 minutes). *)
    user_id : string;
      (** ElastiCache user id. Must match the [user-name] on the
          ElastiCache user created with [--authentication-mode
          Type=iam] — ElastiCache normalises both to lowercase. *)
    cluster_id : string;
      (** Replication group id / serverless cache name. Passed
          through [String.lowercase_ascii] by the signer. *)
    region : string;
      (** AWS region, e.g. ["us-east-1"]. *)
  }

  val default :
    user_id:string -> cluster_id:string -> region:string -> t
  (** [refresh_interval = 600.0]. *)
end

type t

val create :
  sw:Eio.Switch.t ->
  clock:_ Eio.Time.clock ->
  credentials:Iam_credentials.t ->
  config:Config.t ->
  t
(** Signs an initial token eagerly; spawns a refresh fiber on
    [sw] that re-signs every [config.refresh_interval] seconds.
    The fiber exits when [sw] is released. *)

val auth_provider : t -> Connection.Auth.provider
(** Connection hook. The provider's [name] is ["iam"]; the
    closure returns [(user_id, current_token)] on every call
    by atomic-reading the cached token — no signing in the hot
    path, no blocking. *)

type registration
(** Opaque token returned by {!register} so the caller can
    unwire later via {!unregister}. Tokens are cheap — compare
    by physical identity; do not serialise. *)

val register : t -> (unit -> Connection.t list) -> registration
(** Register a connection-enumerator. On every refresh tick the
    provider calls every registered enumerator, collects the
    resulting connections, and sends
    [AUTH user_id token] to each via
    {!Connection.refresh_auth}.

    The enumerator model lets dynamic topologies (cluster mode,
    pools that grow and shrink) hand over a [fun () ->
    Node_pool.all_connections pool] closure once; the provider
    discovers new connections on every tick without any further
    bookkeeping.

    Standalone callers typically register a stable
    [fun () -> fixed_bundle_list] closure.

    On AUTH failure the connection self-transitions to
    Recovering and the supervisor re-handshakes using this
    provider's {!auth_provider} — no separate reconnect
    handling needed. Dead connections returned by the
    enumerator are simply skipped on the tick. *)

val unregister : t -> registration -> unit
(** Remove an enumerator previously installed by {!register}.
    Idempotent; unregistering an already-removed token is a
    no-op. *)

val force_refresh : t -> unit
(** Re-sign immediately and push AUTH to every registered live
    connection. Exposed for tests and for callers that want to
    rotate on demand (e.g. after rotating the IAM role). *)

val current_token : t -> string
(** Read the cached token without forcing a refresh. Useful for
    tests and for diagnostic tools. *)
