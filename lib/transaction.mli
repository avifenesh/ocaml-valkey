(** MULTI / EXEC transactions.

    A transaction groups a sequence of commands that are submitted
    atomically and run in order on a single Valkey server.
    Optionally uses [WATCH] for optimistic concurrency control: if
    any watched key is modified between [begin_] and [exec], [exec]
    reports an abort (returns [Ok None]) and the queued commands do
    not run.

    {1 Important: use a dedicated Client}

    Transactions pin one connection from the client's router and
    drive a MULTI/EXEC block on it, bypassing the multiplexed retry
    machinery. If other fibers call commands on the same
    [Client.t] while a transaction is open, the interleaved traffic
    corrupts both the transaction and the concurrent command.

    Same rule as blocking commands: open a dedicated [Client.t]
    and use it single-threaded for the transaction's duration.

    {1 Cluster mode}

    Every key referenced inside the transaction (queued commands
    plus [watch]) must hash to the same slot. The server rejects
    cross-slot transactions with [CROSSSLOT] and that surfaces as
    a [Server_error] on the offending call.

    Pass [hint_key] so [begin_] can pin to the right primary —
    typically one of the keys you're about to operate on. In
    standalone mode [hint_key] is ignored (there's only one node). *)

type t

val begin_ :
  ?hint_key:string ->
  ?watch:string list ->
  Client.t ->
  (t, Connection.Error.t) result
(** Start a transaction. Sends optional [WATCH] then [MULTI] on the
    pinned connection. On any error the returned result is [Error]
    and no transaction is open. *)

val queue :
  t -> string array -> (unit, Connection.Error.t) result
(** Add a command to the pending transaction. The server replies
    [+QUEUED] on success; anything else (wrong arity, unknown
    command, [CROSSSLOT]) is surfaced so the caller can choose to
    [discard]. *)

val exec :
  t -> (Resp3.t list option, Connection.Error.t) result
(** Run [EXEC] and return per-queued-command replies in order.

    - [Ok (Some replies)] — transaction committed.
    - [Ok None]           — WATCH observed a modification on one of
                            the watched keys; queued commands were
                            not run. Caller decides whether to retry.
    - [Error _]           — transport / protocol failure; the
                            transaction's outcome is unknown. *)

val discard : t -> (unit, Connection.Error.t) result
(** Abort the transaction without running [EXEC]. Safe to call
    after any partial failure; a successful [discard] releases the
    transaction state. *)

val with_transaction :
  ?hint_key:string ->
  ?watch:string list ->
  Client.t ->
  (t -> unit) ->
  (Resp3.t list option, Connection.Error.t) result
(** Convenience wrapper: [begin_] → [f t] → [exec]. If [f] raises
    an exception, the transaction is [discard]ed before the
    exception re-raises. *)
