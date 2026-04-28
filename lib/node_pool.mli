(** Per-node multiplexed-connection bundle. A bundle has N ≥ 1 live
    {!Connection.t}s to the same cluster node; all share a Client_cache
    reference, all have independent CLIENT ID / circuit breaker /
    reconnect state.

    Default N = 1. N > 1 is the throughput knob
    ([Client.Config.connections_per_node] /
    [Cluster_router.Config.connections_per_node]); at N = 1
    this module is a thin re-implementation of the old
    one-conn-per-node model and the two pick functions return
    the same single connection.

    Thread-safe across domains. The read path ([pick],
    [pick_for_slot], [node_ids], [all_connections], [size],
    [total_conns]) is lock-free — the bundle hashtable is
    snapshot-published via an [Atomic.t]. Writers
    ([add_bundle], [remove_bundle], [close_all]) serialise
    under a single mutex and copy-on-write a fresh hashtable
    before [Atomic.set]. *)

type t

val create : unit -> t

val validate_bundle_size : int -> unit
(** [validate_bundle_size n] raises [Invalid_argument] unless
    [n >= 1]. Single canonical check so
    [Client.Config.connections_per_node] and
    [Cluster_router.Config.connections_per_node] share the
    same validation rule and message shape. *)

val add_bundle : t -> node_id:string -> Connection.t array -> unit
(** Install [conns] as the bundle for [node_id]. Replaces any
    existing bundle (caller is responsible for closing the old
    one — use {!remove_bundle} first if a handoff is needed).
    [conns] must be non-empty. *)

val remove_bundle : t -> node_id:string -> Connection.t array option
(** Removes and returns the bundle so the caller can close each
    conn. Returns [None] if [node_id] was not present. *)

val pick : t -> node_id:string -> Connection.t option
(** Round-robin pick for single-reply dispatch. A single pool-wide
    counter rotates across all bundle indices so concurrent fibers
    land on different conns fairly under Eio's cooperative
    scheduling. Used by [exec], [exec_multi] per-node dispatch, and
    every non-atomic single-command path.

    Returns [None] if [node_id] has no bundle. *)

val pick_for_slot :
  t -> node_id:string -> slot:int -> Connection.t option
(** Slot-affinity pick: always returns bundle.([slot mod bundle_size]).
    Required for atomic multi-frame submits (OPTIN CSC
    [CACHING YES + read], ASK [CACHING YES + ASKING + read]) where
    frame 1 arms per-connection state that frame 2 must consume on
    the same wire. A round-robin pick here would either

    - land the two frames on different conns (breaking OPTIN/ASK
      atomicity), or
    - be forced to pin every pair submit onto [bundle.(0)], which
      would defeat N-conn scaling for cache-heavy workloads.

    Slot affinity distributes pair traffic evenly across the bundle
    for a well-balanced keyspace.

    Returns [None] if [node_id] has no bundle. *)

val node_ids : t -> string list

val all_connections : t -> Connection.t list
(** Flattened view across all nodes × bundle entries. Used by
    {!close_all} and observability (e.g. invalidator drain). *)

val close_all : t -> unit
(** Closes every Connection in every bundle and clears the table. *)

val size : t -> int
(** Number of distinct [node_id]s. *)

val total_conns : t -> int
(** Sum of bundle sizes across the whole pool — the live
    multiplexed-conn count. *)
