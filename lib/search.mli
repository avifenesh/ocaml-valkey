(** Typed helpers for the Valkey Search module.

    Valkey Search commands operate on indexes rather than on Valkey
    key slots. The wrappers here therefore route through a random
    node in cluster mode. Metadata writes are always sent to a
    primary. Reads also default to primaries; pass [~read_from] only
    when the application accepts replica/index lag. *)

type data_type =
  | Hash
  | Json

type text_suffix_trie =
  | Suffix_default
  | With_suffix_trie
  | No_suffix_trie

type distance_metric =
  | L2
  | Ip
  | Cosine

type field

val text :
  ?alias:string ->
  ?sortable:bool ->
  ?no_stem:bool ->
  ?suffix_trie:text_suffix_trie ->
  ?weight:float ->
  string ->
  field

val tag :
  ?alias:string ->
  ?sortable:bool ->
  ?separator:char ->
  ?case_sensitive:bool ->
  string ->
  field

val numeric : ?alias:string -> ?sortable:bool -> string -> field

val vector_flat :
  ?alias:string ->
  ?sortable:bool ->
  ?initial_cap:int ->
  dim:int ->
  distance_metric:distance_metric ->
  string ->
  field

val vector_hnsw :
  ?alias:string ->
  ?sortable:bool ->
  ?initial_cap:int ->
  ?m:int ->
  ?ef_construction:int ->
  ?ef_runtime:int ->
  dim:int ->
  distance_metric:distance_metric ->
  string ->
  field

type offsets =
  | With_offsets
  | No_offsets

type stopwords =
  | Default_stopwords
  | No_stopwords
  | Stopwords of string list

type create_options = {
  data_type : data_type;
  prefixes : string list;
  score : float option;
  language : string option;
  min_stem_size : int option;
  offsets : offsets;
  stopwords : stopwords;
  punctuation : string option;
  skip_initial_scan : bool;
}

val default_create_options : create_options

val create :
  ?timeout:float ->
  ?options:create_options ->
  Client.t ->
  index:string ->
  schema:field list ->
  (unit, Connection.Error.t) result
(** Create an index with [FT.CREATE]. *)

val drop_index :
  ?timeout:float ->
  Client.t ->
  string ->
  (unit, Connection.Error.t) result
(** Drop an index with [FT.DROPINDEX]. *)

val list_indexes :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  Client.t ->
  (string list, Connection.Error.t) result
(** List the indexes in the selected database with [FT._LIST]. *)

type shard_policy =
  | All_shards
  | Some_shards

type consistency =
  | Consistent
  | Inconsistent

type info_scope =
  | Local
  | Primary
  | Cluster

type info_options = {
  scope : info_scope;
  shard_policy : shard_policy;
  consistency : consistency;
}

val default_info_options : info_options

val info_raw :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?options:info_options ->
  Client.t ->
  string ->
  ((string * Resp3.t) list, Connection.Error.t) result
(** Return the raw [FT.INFO] key/value pairs. The Search module still
    evolves quickly, so the library keeps the full server payload
    instead of baking every metric into a lossy record. *)

type sort_direction =
  | Asc
  | Desc

type return_field = {
  field : string;
  alias : string option;
}

val return_field : ?alias:string -> string -> return_field

type search_sort = {
  by : string;
  direction : sort_direction option;
}

val search_sort : ?direction:sort_direction -> string -> search_sort

type search_options = {
  shard_policy : shard_policy;
  consistency : consistency;
  dialect : int option;
  inorder : bool;
  limit : (int * int) option;
  no_content : bool;
  params : (string * string) list;
  return_fields : return_field list option;
  slop : int option;
  sort_by : search_sort option;
  timeout_ms : int option;
  verbatim : bool;
  with_sort_keys : bool;
}

val default_search_options : search_options

type document = {
  key : string;
  sort_key : Resp3.t option;
  fields : (string * Resp3.t) list;
}

type search_result = {
  total : int64;
  documents : document list;
}

val search :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?options:search_options ->
  Client.t ->
  index:string ->
  query:string ->
  (search_result, Connection.Error.t) result
(** Run [FT.SEARCH]. Field values are kept as [Resp3.t] so HASH,
    JSON, vector-distance, and future module payloads remain
    representable without string coercion. *)

type load =
  | Load_all
  | Load_fields of string list

type reducer =
  | Count
  | Count_distinct of string
  | Sum of string
  | Min of string
  | Max of string
  | Avg of string
  | Stddev of string
  | Custom_reducer of { name : string; args : string list }

type group_reducer = {
  reducer : reducer;
  reducer_alias : string option;
}

val group_reducer : ?alias:string -> reducer -> group_reducer

type aggregate_sort = {
  expression : string;
  sort_direction : sort_direction option;
}

val aggregate_sort :
  ?direction:sort_direction -> string -> aggregate_sort

type aggregate_stage =
  | Apply of { expression : string; alias : string }
  | Filter of string
  | Group_by of {
      fields : string list;
      reducers : group_reducer list;
    }
  | Limit of { offset : int; count : int }
  | Sort_by of {
      fields : aggregate_sort list;
      max : int option;
    }

type aggregate_options = {
  dialect : int option;
  inorder : bool;
  load : load option;
  params : (string * string) list;
  slop : int option;
  timeout_ms : int option;
  verbatim : bool;
  stages : aggregate_stage list;
}

val default_aggregate_options : aggregate_options

type aggregate_result = {
  header : Resp3.t;
  rows : (string * Resp3.t) list list;
}

val aggregate :
  ?timeout:float ->
  ?read_from:Client.Read_from.t ->
  ?options:aggregate_options ->
  Client.t ->
  index:string ->
  query:string ->
  (aggregate_result, Connection.Error.t) result
(** Run [FT.AGGREGATE]. The first response element has no stable
    semantics in Valkey's command reference, so it is exposed as
    [header] and row records are decoded as field/value pairs. *)

module For_testing : sig
  val create_args :
    options:create_options -> index:string -> schema:field list -> string array

  val search_args :
    options:search_options -> index:string -> query:string -> string array

  val aggregate_args :
    options:aggregate_options -> index:string -> query:string -> string array

  val decode_search :
    options:search_options ->
    Resp3.t ->
    (search_result, Connection.Error.t) result

  val decode_aggregate :
    Resp3.t -> (aggregate_result, Connection.Error.t) result

  val decode_info_raw :
    Resp3.t -> ((string * Resp3.t) list, Connection.Error.t) result
end
