(** MULTI / EXEC transactions.

    A transaction groups a sequence of commands that are submitted
    atomically and run in order on a single Valkey server.
    Optionally uses [WATCH] for optimistic concurrency control: if
    any watched key is modified between [begin_] and [exec], [exec]
    reports an abort (returns [Ok None]) and the queued commands do
    not run.

    {1 Relationship to [Batch]}

    Transaction is a thin wrapper over atomic {!Batch}: [begin_]
    with [~watch:] opens a {!Batch.guard} (so the watched primary's
    atomic mutex is held across the user's code); [queue] appends
    to a buffered [Batch.t ~atomic:true]; [exec] sends the whole
    block via {!Batch.run_with_guard} (or {!Batch.run} when there's
    no watch). Pick whichever feels more natural for the call site;
    the semantics are identical.

    One consequence of the fold: bad-arity / unknown-command
    errors surface inside the per-command replies returned by
    [exec] (as [Resp3.Simple_error _]) or via an [EXECABORT] reply,
    not at [queue] time. Structural rejections (fan-out commands
    inside an atomic block) still fail fast at [queue] with a
    [Terminal] error — those can't atomically dispatch so queueing
    them is unambiguously a user bug.

    {1 Cluster mode}

    Every key referenced inside the transaction (queued commands
    plus [watch]) must hash to the same slot. Mismatches surface
    as [Server_error { code = "CROSSSLOT"; … }] at [exec] time.
    Pass [hint_key] so the slot can be pinned up front — typically
    one of the keys you're about to operate on. In standalone mode
    [hint_key] is ignored (there's only one node).

    {1 Concurrency}

    Concurrent transactions on the same primary serialise at
    [exec] time via the router's per-primary atomic mutex (see
    {!Client.atomic_lock_for_slot}). Local [queue] calls on
    different [t] values never interact. Non-atomic pipeline
    traffic on the same [Client.t] continues to multiplex
    normally and does not contend with in-flight transactions. *)

type t

val begin_ :
  ?hint_key:string ->
  ?watch:string list ->
  Client.t ->
  (t, Connection.Error.t) result
(** Start a transaction. When [~watch] is non-empty, opens a
    {!Batch.guard}: sends [WATCH] immediately on the pinned primary's
    connection and holds that primary's atomic mutex until [exec] or
    [discard]. With no [~watch], nothing is sent yet; the mutex is
    acquired only for the brief MULTI/EXEC window inside [exec]. *)

val queue :
  t -> string array -> (unit, Connection.Error.t) result
(** Append a command to the pending transaction. Succeeds unless the
    command is a fan-out (e.g. [SCRIPT LOAD], [FLUSHALL]) — those
    can't atomically dispatch inside MULTI/EXEC and are rejected
    with a [Terminal] error. Server-side per-command validation
    (wrong arity, unknown command) now surfaces inside the
    [exec]-returned list, not here. *)

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
