module Read_from = struct
  type t =
    | Primary
    | Prefer_replica
    | Az_affinity of { az : string }
    | Az_affinity_replicas_and_primary of { az : string }

  let default = Primary
end

module Target = struct
  type t =
    | Random
    | All_nodes
    | All_primaries
    | By_slot of int
    | By_node of string
    | By_channel of string
end

type t = {
  exec :
    ?timeout:float -> Target.t -> Read_from.t -> string array ->
    (Resp3.t, Connection.Error.t) result;
  close : unit -> unit;
  primary : unit -> Connection.t option;
}
[@@warning "-69"]

let make ~exec ~close ~primary = { exec; close; primary }

let standalone (conn : Connection.t) : t =
  { exec = (fun ?timeout _target _read_from args ->
      Connection.request ?timeout conn args);
    close = (fun () -> Connection.close conn);
    primary = (fun () -> Some conn);
  }

let exec ?timeout t target rf args = t.exec ?timeout target rf args
let close t = t.close ()
let primary_connection t = t.primary ()
