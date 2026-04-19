(** Abstract routing dispatcher. Both the standalone and cluster modes
    produce a [Router.t]; command layers (Client) use it uniformly. *)

module Read_from : sig
  type t =
    | Primary
    | Prefer_replica
    | Az_affinity of { az : string }
    | Az_affinity_replicas_and_primary of { az : string }

  val default : t
end

module Target : sig
  type t =
    | Random
    | All_nodes
    | All_primaries
    | By_slot of int
    | By_node of string
    | By_channel of string
end

type t

val make :
  exec:(?timeout:float -> Target.t -> Read_from.t -> string array ->
        (Resp3.t, Connection.Error.t) result) ->
  close:(unit -> unit) ->
  primary:(unit -> Connection.t option) ->
  t

val standalone : Connection.t -> t

val exec :
  ?timeout:float -> t -> Target.t -> Read_from.t -> string array ->
  (Resp3.t, Connection.Error.t) result

val close : t -> unit

val primary_connection : t -> Connection.t option
