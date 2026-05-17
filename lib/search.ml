module R = Resp3
module E = Connection.Error

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

type text_options = {
  no_stem : bool;
  suffix_trie : text_suffix_trie;
  weight : float option;
}

type tag_options = {
  separator : char option;
  case_sensitive : bool;
}

type flat_options = {
  flat_dim : int;
  flat_distance_metric : distance_metric;
  flat_initial_cap : int option;
}

type hnsw_options = {
  hnsw_dim : int;
  hnsw_distance_metric : distance_metric;
  hnsw_initial_cap : int option;
  hnsw_m : int option;
  hnsw_ef_construction : int option;
  hnsw_ef_runtime : int option;
}

type field_kind =
  | Text of text_options
  | Tag of tag_options
  | Numeric
  | Vector_flat of flat_options
  | Vector_hnsw of hnsw_options

type field = {
  identifier : string;
  alias : string option;
  sortable : bool;
  kind : field_kind;
}

let text
    ?alias ?(sortable = false) ?(no_stem = false)
    ?(suffix_trie = Suffix_default) ?weight identifier =
  { identifier;
    alias;
    sortable;
    kind = Text { no_stem; suffix_trie; weight };
  }

let tag
    ?alias ?(sortable = false) ?separator ?(case_sensitive = false)
    identifier =
  { identifier;
    alias;
    sortable;
    kind = Tag { separator; case_sensitive };
  }

let numeric ?alias ?(sortable = false) identifier =
  { identifier; alias; sortable; kind = Numeric }

let vector_flat
    ?alias ?(sortable = false) ?initial_cap
    ~dim ~distance_metric identifier =
  { identifier;
    alias;
    sortable;
    kind =
      Vector_flat
        { flat_dim = dim;
          flat_distance_metric = distance_metric;
          flat_initial_cap = initial_cap;
        };
  }

let vector_hnsw
    ?alias ?(sortable = false) ?initial_cap ?m ?ef_construction
    ?ef_runtime ~dim ~distance_metric identifier =
  { identifier;
    alias;
    sortable;
    kind =
      Vector_hnsw
        { hnsw_dim = dim;
          hnsw_distance_metric = distance_metric;
          hnsw_initial_cap = initial_cap;
          hnsw_m = m;
          hnsw_ef_construction = ef_construction;
          hnsw_ef_runtime = ef_runtime;
        };
  }

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

let default_create_options =
  { data_type = Hash;
    prefixes = [];
    score = None;
    language = None;
    min_stem_size = None;
    offsets = With_offsets;
    stopwords = Default_stopwords;
    punctuation = None;
    skip_initial_scan = false;
  }

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

let default_info_options =
  { scope = Local; shard_policy = All_shards; consistency = Consistent }

type sort_direction =
  | Asc
  | Desc

type return_field = {
  field : string;
  alias : string option;
}

let return_field ?alias field = { field; alias }

type search_sort = {
  by : string;
  direction : sort_direction option;
}

let search_sort ?direction by = { by; direction }

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

let default_search_options =
  { shard_policy = All_shards;
    consistency = Consistent;
    dialect = None;
    inorder = false;
    limit = None;
    no_content = false;
    params = [];
    return_fields = None;
    slop = None;
    sort_by = None;
    timeout_ms = None;
    verbatim = false;
    with_sort_keys = false;
  }

type document = {
  key : string;
  sort_key : Resp3.t option;
  fields : (string * Resp3.t) list;
}

type search_result = {
  total : int64;
  documents : document list;
}

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

let group_reducer ?alias reducer = { reducer; reducer_alias = alias }

type aggregate_sort = {
  expression : string;
  sort_direction : sort_direction option;
}

let aggregate_sort ?direction expression =
  { expression; sort_direction = direction }

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

let default_aggregate_options =
  { dialect = None;
    inorder = false;
    load = None;
    params = [];
    slop = None;
    timeout_ms = None;
    verbatim = false;
    stages = [];
  }

type aggregate_result = {
  header : Resp3.t;
  rows : (string * Resp3.t) list list;
}

let ( let* ) = Result.bind

let protocol_violation cmd v =
  E.Protocol_violation
    (Format.asprintf "%s: unexpected reply %a" cmd R.pp v)

let string_of_float f = Printf.sprintf "%.17g" f

let data_type_arg = function
  | Hash -> "HASH"
  | Json -> "JSON"

let suffix_trie_args = function
  | Suffix_default -> []
  | With_suffix_trie -> [ "WITHSUFFIXTRIE" ]
  | No_suffix_trie -> [ "NOSUFFIXTRIE" ]

let distance_metric_arg = function
  | L2 -> "L2"
  | Ip -> "IP"
  | Cosine -> "COSINE"

let sort_direction_arg = function
  | Asc -> "ASC"
  | Desc -> "DESC"

let opt_arg name to_string = function
  | None -> []
  | Some v -> [ name; to_string v ]

let alias_args = function
  | None -> []
  | Some alias -> [ "AS"; alias ]

let bool_arg name enabled = if enabled then [ name ] else []

let vector_args algorithm attrs =
  [ "VECTOR"; algorithm; string_of_int (List.length attrs) ] @ attrs

let field_kind_args = function
  | Numeric -> [ "NUMERIC" ]
  | Tag { separator; case_sensitive } ->
      [ "TAG" ]
      @ opt_arg "SEPARATOR" (String.make 1) separator
      @ bool_arg "CASESENSITIVE" case_sensitive
  | Text { no_stem; suffix_trie; weight } ->
      [ "TEXT" ]
      @ bool_arg "NOSTEM" no_stem
      @ suffix_trie_args suffix_trie
      @ opt_arg "WEIGHT" string_of_float weight
  | Vector_flat { flat_dim; flat_distance_metric; flat_initial_cap } ->
      let attrs =
        [ "TYPE"; "FLOAT32";
          "DIM"; string_of_int flat_dim;
          "DISTANCE_METRIC"; distance_metric_arg flat_distance_metric;
        ]
        @ opt_arg "INITIAL_CAP" string_of_int flat_initial_cap
      in
      vector_args "FLAT" attrs
  | Vector_hnsw
      { hnsw_dim;
        hnsw_distance_metric;
        hnsw_initial_cap;
        hnsw_m;
        hnsw_ef_construction;
        hnsw_ef_runtime;
      } ->
      let attrs =
        [ "TYPE"; "FLOAT32";
          "DIM"; string_of_int hnsw_dim;
          "DISTANCE_METRIC"; distance_metric_arg hnsw_distance_metric;
        ]
        @ opt_arg "INITIAL_CAP" string_of_int hnsw_initial_cap
        @ opt_arg "M" string_of_int hnsw_m
        @ opt_arg "EF_CONSTRUCTION" string_of_int hnsw_ef_construction
        @ opt_arg "EF_RUNTIME" string_of_int hnsw_ef_runtime
      in
      vector_args "HNSW" attrs

let field_args field =
  [ field.identifier ]
  @ alias_args field.alias
  @ field_kind_args field.kind
  @ bool_arg "SORTABLE" field.sortable

let create_args ~options ~index ~schema =
  let prefix_args =
    match options.prefixes with
    | [] -> []
    | prefixes ->
        "PREFIX" :: string_of_int (List.length prefixes) :: prefixes
  in
  let score_args = opt_arg "SCORE" string_of_float options.score in
  let language_args = opt_arg "LANGUAGE" Fun.id options.language in
  let min_stem_args =
    opt_arg "MINSTEMSIZE" string_of_int options.min_stem_size
  in
  let offsets_args =
    match options.offsets with
    | With_offsets -> []
    | No_offsets -> [ "NOOFFSETS" ]
  in
  let stopword_args =
    match options.stopwords with
    | Default_stopwords -> []
    | No_stopwords -> [ "NOSTOPWORDS" ]
    | Stopwords words ->
        "STOPWORDS" :: string_of_int (List.length words) :: words
  in
  let punctuation_args = opt_arg "PUNCTUATION" Fun.id options.punctuation in
  Array.of_list
    ([ "FT.CREATE"; index; "ON"; data_type_arg options.data_type ]
     @ prefix_args
     @ score_args
     @ language_args
     @ bool_arg "SKIPINITIALSCAN" options.skip_initial_scan
     @ min_stem_args
     @ offsets_args
     @ stopword_args
     @ punctuation_args
     @ [ "SCHEMA" ]
     @ List.concat_map field_args schema)

let shard_policy_arg = function
  | All_shards -> "ALLSHARDS"
  | Some_shards -> "SOMESHARDS"

let consistency_arg = function
  | Consistent -> "CONSISTENT"
  | Inconsistent -> "INCONSISTENT"

let info_scope_arg = function
  | Local -> "LOCAL"
  | Primary -> "PRIMARY"
  | Cluster -> "CLUSTER"

let info_args ~options ~index =
  let scope =
    match options.scope with
    | Local -> []
    | Primary | Cluster as scope -> [ info_scope_arg scope ]
  in
  let shard_policy =
    match options.shard_policy with
    | All_shards -> []
    | Some_shards -> [ shard_policy_arg Some_shards ]
  in
  let consistency =
    match options.consistency with
    | Consistent -> []
    | Inconsistent -> [ consistency_arg Inconsistent ]
  in
  Array.of_list ([ "FT.INFO"; index ] @ scope @ shard_policy @ consistency)

let params_args params =
  match params with
  | [] -> []
  | pairs ->
      "PARAMS" :: string_of_int (2 * List.length pairs)
      :: List.concat_map (fun (name, value) -> [ name; value ]) pairs

let return_field_args { field; alias } =
  field :: alias_args alias

let search_args ~options ~index ~query =
  let limit =
    match options.limit with
    | None -> []
    | Some (offset, count) ->
        [ "LIMIT"; string_of_int offset; string_of_int count ]
  in
  let return_fields =
    match options.return_fields with
    | None -> []
    | Some fields ->
        "RETURN" :: string_of_int (List.length fields)
        :: List.concat_map return_field_args fields
  in
  let sort_by =
    match options.sort_by with
    | None -> []
    | Some { by; direction } ->
        [ "SORTBY"; by ]
        @ (match direction with
           | None -> []
           | Some d -> [ sort_direction_arg d ])
  in
  Array.of_list
    ([ "FT.SEARCH";
       index;
       query;
       shard_policy_arg options.shard_policy;
       consistency_arg options.consistency;
     ]
     @ opt_arg "DIALECT" string_of_int options.dialect
     @ bool_arg "INORDER" options.inorder
     @ limit
     @ bool_arg "NOCONTENT" options.no_content
     @ params_args options.params
     @ return_fields
     @ opt_arg "SLOP" string_of_int options.slop
     @ sort_by
     @ opt_arg "TIMEOUT" string_of_int options.timeout_ms
     @ bool_arg "VERBATIM" options.verbatim
     @ bool_arg "WITHSORTKEYS" options.with_sort_keys)

let load_args = function
  | None -> []
  | Some Load_all -> [ "LOAD"; "*" ]
  | Some (Load_fields fields) ->
      "LOAD" :: string_of_int (List.length fields) :: fields

let reducer_args { reducer; reducer_alias } =
  let name, args =
    match reducer with
    | Count -> "COUNT", []
    | Count_distinct expr -> "COUNT_DISTINCT", [ expr ]
    | Sum expr -> "SUM", [ expr ]
    | Min expr -> "MIN", [ expr ]
    | Max expr -> "MAX", [ expr ]
    | Avg expr -> "AVG", [ expr ]
    | Stddev expr -> "STDDEV", [ expr ]
    | Custom_reducer { name; args } -> name, args
  in
  [ "REDUCE"; name; string_of_int (List.length args) ]
  @ args
  @ alias_args reducer_alias

let aggregate_sort_args { expression; sort_direction } =
  expression
  :: (match sort_direction with
      | None -> []
      | Some d -> [ sort_direction_arg d ])

let aggregate_stage_args = function
  | Apply { expression; alias } -> [ "APPLY"; expression; "AS"; alias ]
  | Filter expression -> [ "FILTER"; expression ]
  | Group_by { fields; reducers } ->
      "GROUPBY" :: string_of_int (List.length fields) :: fields
      @ List.concat_map reducer_args reducers
  | Limit { offset; count } ->
      [ "LIMIT"; string_of_int offset; string_of_int count ]
  | Sort_by { fields; max } ->
      let sort_params = List.concat_map aggregate_sort_args fields in
      [ "SORTBY"; string_of_int (List.length sort_params) ]
      @ sort_params
      @ opt_arg "MAX" string_of_int max

let aggregate_args ~options ~index ~query =
  Array.of_list
    ([ "FT.AGGREGATE"; index; query ]
     @ opt_arg "DIALECT" string_of_int options.dialect
     @ bool_arg "INORDER" options.inorder
     @ load_args options.load
     @ params_args options.params
     @ opt_arg "SLOP" string_of_int options.slop
     @ opt_arg "TIMEOUT" string_of_int options.timeout_ms
     @ bool_arg "VERBATIM" options.verbatim
     @ List.concat_map aggregate_stage_args options.stages)

let write ?timeout client args =
  Client.exec ?timeout ~target:Client.Target.Random
    ~read_from:Client.Read_from.Primary client args

let read ?timeout ?read_from client args =
  let read_from =
    Option.value read_from ~default:Client.Read_from.Primary
  in
  Client.exec ?timeout ~target:Client.Target.Random ~read_from client args

let expect_ok cmd = function
  | Ok (R.Simple_string "OK") | Ok (R.Bulk_string "OK") -> Ok ()
  | Ok v -> Error (protocol_violation cmd v)
  | Error e -> Error e

let create ?timeout ?(options = default_create_options)
    client ~index ~schema =
  expect_ok "FT.CREATE"
    (write ?timeout client (create_args ~options ~index ~schema))

let drop_index ?timeout client index =
  expect_ok "FT.DROPINDEX"
    (write ?timeout client [| "FT.DROPINDEX"; index |])

let string_of_resp cmd = function
  | R.Bulk_string s | R.Simple_string s
  | R.Verbatim_string { data = s; _ } -> Ok s
  | v -> Error (protocol_violation cmd v)

let decode_string_list cmd = function
  | R.Array items | R.Set items ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
            let* s = string_of_resp cmd item in
            loop (s :: acc) rest
      in
      loop [] items
  | v -> Error (protocol_violation cmd v)

let list_indexes ?timeout ?read_from client =
  match read ?timeout ?read_from client [| "FT._LIST" |] with
  | Error e -> Error e
  | Ok reply -> decode_string_list "FT._LIST" reply

let decode_pairs cmd = function
  | R.Map entries ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | (k, v) :: rest ->
            let* key = string_of_resp cmd k in
            loop ((key, v) :: acc) rest
      in
      loop [] entries
  | R.Array items ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | key :: value :: rest ->
            let* key = string_of_resp cmd key in
            loop ((key, value) :: acc) rest
        | [ _ ] -> Error (protocol_violation cmd (R.Array items))
      in
      loop [] items
  | v -> Error (protocol_violation cmd v)

let decode_info_raw = decode_pairs "FT.INFO"

let info_raw ?timeout ?read_from ?(options = default_info_options)
    client index =
  match read ?timeout ?read_from client (info_args ~options ~index) with
  | Error e -> Error e
  | Ok reply -> decode_info_raw reply

let decode_fields = decode_pairs "FT.SEARCH"

let decode_search ~options = function
  | R.Array (R.Integer total :: rest) ->
      let no_fields =
        options.no_content ||
        (match options.return_fields with Some [] -> true | _ -> false)
      in
      let rec loop acc = function
        | [] -> Ok { total; documents = List.rev acc }
        | key :: tail ->
            let* key = string_of_resp "FT.SEARCH key" key in
            if no_fields then
              if options.with_sort_keys then
                match tail with
                | sort_key :: tail ->
                    loop ({ key; sort_key = Some sort_key; fields = [] } :: acc) tail
                | [] -> Error (protocol_violation "FT.SEARCH" (R.Array rest))
              else
                loop ({ key; sort_key = None; fields = [] } :: acc) tail
            else if options.with_sort_keys then
              (match tail with
               | sort_key :: (R.Array _ | R.Map _ as field_reply) :: tail ->
                   let* fields = decode_fields field_reply in
                   loop ({ key; sort_key = Some sort_key; fields } :: acc) tail
               | (R.Array _ | R.Map _ as field_reply) :: tail ->
                   let* fields = decode_fields field_reply in
                   loop ({ key; sort_key = None; fields } :: acc) tail
               | _ -> Error (protocol_violation "FT.SEARCH" (R.Array rest)))
            else
              (match tail with
               | (R.Array _ | R.Map _ as field_reply) :: tail ->
                   let* fields = decode_fields field_reply in
                   loop ({ key; sort_key = None; fields } :: acc) tail
               | _ -> Error (protocol_violation "FT.SEARCH" (R.Array rest)))
      in
      loop [] rest
  | v -> Error (protocol_violation "FT.SEARCH" v)

let search ?timeout ?read_from ?(options = default_search_options)
    client ~index ~query =
  match read ?timeout ?read_from client (search_args ~options ~index ~query) with
  | Error e -> Error e
  | Ok reply -> decode_search ~options reply

let decode_aggregate = function
  | R.Array (header :: rows) ->
      let rec loop acc = function
        | [] -> Ok { header; rows = List.rev acc }
        | (R.Array _ | R.Map _ as field_reply) :: rest ->
            let* fields = decode_pairs "FT.AGGREGATE" field_reply in
            loop (fields :: acc) rest
        | other :: _ -> Error (protocol_violation "FT.AGGREGATE" other)
      in
      loop [] rows
  | v -> Error (protocol_violation "FT.AGGREGATE" v)

let aggregate ?timeout ?read_from ?(options = default_aggregate_options)
    client ~index ~query =
  match
    read ?timeout ?read_from client (aggregate_args ~options ~index ~query)
  with
  | Error e -> Error e
  | Ok reply -> decode_aggregate reply

module For_testing = struct
  let create_args = create_args
  let search_args = search_args
  let aggregate_args = aggregate_args
  let decode_search ~options reply = decode_search ~options reply
  let decode_aggregate = decode_aggregate
  let decode_info_raw = decode_info_raw
end
