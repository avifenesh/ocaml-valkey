(** Typed view of a RESP3 CSC invalidation push.

    The wire-level push frame has been parsed by {!Resp3_parser}
    already; this module validates the semantic shape and lifts it
    to a domain type. See [docs/client-side-caching.md]. *)

type t =
  | Keys of string list
  (** Invalidate exactly these keys. Possibly empty (server sends a
      vacuous invalidation occasionally; drop cleanly). *)
  | Flush_all
  (** Full-flush invalidation. Sent when the server executes
      [FLUSHDB] / [FLUSHALL] — every cached entry must be evicted. *)

(** [of_push v] returns [Some] iff [v] is a well-formed RESP3 CSC
    invalidation push:

    - [> "invalidate" Null] → [Flush_all]
    - [> "invalidate" (Array keys)] where every key is a
      [Bulk_string] → [Keys keys]

    Everything else (non-push frames, pubsub pushes, malformed
    bodies, non-string keys) returns [None]. The invalidator fiber
    treats [None] as "not ours, skip". *)
val of_push : Resp3.t -> t option

(** [apply cache inv] performs the cache mutation the invalidation
    demands: [Flush_all] clears the cache; [Keys ks] evicts each
    key. Pulled out of the fiber body so its effect is unit-
    testable without an Eio runtime. *)
val apply : Cache.t -> t -> unit
