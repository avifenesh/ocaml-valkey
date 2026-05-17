(** Typed helpers for the Valkey JSON module.

    The API keeps JSON payloads as serialized strings instead of
    depending on a particular OCaml JSON library. Callers can use
    Yojson, jsonm, ppx_deriving_yojson, or hand-written encoders at
    the boundary and pass the resulting JSON text here.

    Commands route by document key, so they work correctly in cluster
    mode as long as multi-key calls use co-located keys when Valkey
    requires it. *)

type set_condition =
  | If_missing
  | If_exists
(** Mutually exclusive [JSON.SET] existence conditions. *)

type get_format = {
  indent : string option;
  newline : string option;
  space : string option;
  no_escape : bool;
}
(** Optional [JSON.GET] formatting controls. *)

val default_get_format : get_format

val set :
  ?timeout:float ->
  ?condition:set_condition ->
  ?path:string ->
  Client.t ->
  key:string ->
  string ->
  (bool, Connection.Error.t) result
(** [JSON.SET key path json]. [path] defaults to [$]. Returns [false]
    when [If_missing] or [If_exists] prevented the write. *)

val get :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?format:get_format ->
  ?paths:string list ->
  Client.t ->
  key:string ->
  (string option, Connection.Error.t) result
(** [JSON.GET]. The returned string is the server's serialized JSON
    payload. [None] means the key/path did not exist. *)

type mset_entry = {
  key : string;
  path : string;
  json : string;
}

val mget :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  Client.t ->
  keys:string list ->
  path:string ->
  (string option list, Connection.Error.t) result
(** [JSON.MGET key [key ...] path]. Empty key lists are rejected with
    [Invalid_argument]. In cluster mode the keys should be hashtag
    co-located. *)

val mset :
  ?timeout:float ->
  Client.t ->
  mset_entry list ->
  (unit, Connection.Error.t) result
(** [JSON.MSET key path json [key path json ...]]. Empty entry lists
    are rejected with [Invalid_argument]. In cluster mode the keys
    should be hashtag co-located. *)

val del :
  ?timeout:float ->
  ?path:string ->
  Client.t ->
  key:string ->
  (int, Connection.Error.t) result

val forget :
  ?timeout:float ->
  ?path:string ->
  Client.t ->
  key:string ->
  (int, Connection.Error.t) result
(** Alias for {!del}, matching [JSON.FORGET]. *)

val clear :
  ?timeout:float ->
  ?path:string ->
  Client.t ->
  key:string ->
  (int, Connection.Error.t) result

val num_incr_by :
  ?timeout:float ->
  Client.t ->
  key:string ->
  path:string ->
  float ->
  (string option, Connection.Error.t) result
(** [JSON.NUMINCRBY]. Valkey returns the updated value as JSON text
    (for enhanced paths this is usually a JSON array string). *)

val num_mult_by :
  ?timeout:float ->
  Client.t ->
  key:string ->
  path:string ->
  float ->
  (string option, Connection.Error.t) result

val arr_append :
  ?timeout:float ->
  Client.t ->
  key:string ->
  path:string ->
  string list ->
  (int option list, Connection.Error.t) result

val arr_insert :
  ?timeout:float ->
  Client.t ->
  key:string ->
  path:string ->
  index:int ->
  string list ->
  (int option list, Connection.Error.t) result

val arr_len :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?path:string ->
  Client.t ->
  key:string ->
  (int option list, Connection.Error.t) result

val arr_pop :
  ?timeout:float ->
  ?path:string ->
  ?index:int ->
  Client.t ->
  key:string ->
  (string option list, Connection.Error.t) result

val arr_trim :
  ?timeout:float ->
  Client.t ->
  key:string ->
  path:string ->
  start:int ->
  stop:int ->
  (int option list, Connection.Error.t) result

val arr_index :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?start:int ->
  ?stop:int ->
  Client.t ->
  key:string ->
  path:string ->
  json:string ->
  (int option list, Connection.Error.t) result

val strlen :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?path:string ->
  Client.t ->
  key:string ->
  (int option list, Connection.Error.t) result

val str_append :
  ?timeout:float ->
  ?path:string ->
  Client.t ->
  key:string ->
  string ->
  (int option list, Connection.Error.t) result

val toggle :
  ?timeout:float ->
  Client.t ->
  key:string ->
  path:string ->
  (bool option list, Connection.Error.t) result

val type_of :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?path:string ->
  Client.t ->
  key:string ->
  (string option list, Connection.Error.t) result

val obj_len :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?path:string ->
  Client.t ->
  key:string ->
  (int option list, Connection.Error.t) result

val obj_keys :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?path:string ->
  Client.t ->
  key:string ->
  (string list option list, Connection.Error.t) result
(** [JSON.OBJKEYS]. Restricted paths return [Some keys] as a single
    list; enhanced paths return one entry per match, with [None] for
    missing/non-object matches. *)

val resp :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?path:string ->
  Client.t ->
  key:string ->
  (Resp3.t, Connection.Error.t) result
(** Raw [JSON.RESP] reply. *)

module For_testing : sig
  val set_args :
    ?condition:set_condition -> ?path:string -> key:string -> string -> string array

  val get_args :
    format:get_format -> key:string -> paths:string list -> string array

  val mget_args : keys:string list -> path:string -> string array

  val arr_append_args :
    key:string -> path:string -> string list -> string array

  val decode_get :
    Resp3.t -> (string option, Connection.Error.t) result

  val decode_mget :
    Resp3.t -> (string option list, Connection.Error.t) result

  val decode_type :
    Resp3.t -> (string option list, Connection.Error.t) result

  val decode_int_results :
    string -> Resp3.t -> (int option list, Connection.Error.t) result

  val decode_bool_results :
    string -> Resp3.t -> (bool option list, Connection.Error.t) result

  val decode_obj_keys :
    Resp3.t -> (string list option list, Connection.Error.t) result
end
