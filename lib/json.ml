module R = Resp3
module E = Connection.Error

type set_condition =
  | If_missing
  | If_exists

type get_format = {
  indent : string option;
  newline : string option;
  space : string option;
  no_escape : bool;
}

let default_get_format =
  { indent = None; newline = None; space = None; no_escape = false }

type mset_entry = {
  key : string;
  path : string;
  json : string;
}

let ( let* ) = Result.bind

let protocol_violation cmd v =
  E.Protocol_violation
    (Format.asprintf "%s: unexpected reply %a" cmd R.pp v)

let target key = Client.Target.By_slot (Slot.of_key key)

let write_key ?timeout client key args =
  Client.exec ?timeout ~target:(target key)
    ~read_from:Client.Read_from.Primary client args

let read_key ?timeout ?read_from client key args =
  Client.exec ?timeout ~target:(target key) ?read_from client args

let expect_ok cmd = function
  | Ok (R.Simple_string "OK") | Ok (R.Bulk_string "OK") -> Ok ()
  | Ok v -> Error (protocol_violation cmd v)
  | Error e -> Error e

let expect_set = function
  | Ok (R.Simple_string "OK") | Ok (R.Bulk_string "OK") -> Ok true
  | Ok R.Null -> Ok false
  | Ok v -> Error (protocol_violation "JSON.SET" v)
  | Error e -> Error e

let int_of_int64 cmd n =
  let min = Int64.of_int min_int in
  let max = Int64.of_int max_int in
  if Int64.compare n min < 0 || Int64.compare n max > 0 then
    Error
      (E.Protocol_violation
         (cmd ^ ": integer reply out of OCaml int range: "
          ^ Int64.to_string n))
  else Ok (Int64.to_int n)

let int_of_reply cmd = function
  | Ok (R.Integer n) -> int_of_int64 cmd n
  | Ok v -> Error (protocol_violation cmd v)
  | Error e -> Error e

let string_of_resp cmd = function
  | R.Bulk_string s | R.Simple_string s
  | R.Verbatim_string { data = s; _ } -> Ok s
  | v -> Error (protocol_violation cmd v)

let decode_string_opt cmd = function
  | R.Null -> Ok None
  | v ->
      let* s = string_of_resp cmd v in
      Ok (Some s)

let decode_int_opt cmd = function
  | R.Null -> Ok None
  | R.Integer n ->
      let* n = int_of_int64 cmd n in
      Ok (Some n)
  | v -> Error (protocol_violation cmd v)

let decode_bool_opt cmd = function
  | R.Null -> Ok None
  | R.Boolean b -> Ok (Some b)
  | R.Integer 0L -> Ok (Some false)
  | R.Integer 1L -> Ok (Some true)
  | v -> Error (protocol_violation cmd v)

let decode_many decode cmd = function
  | R.Array items ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
            let* value = decode cmd item in
            loop (value :: acc) rest
      in
      loop [] items
  | item ->
      let* value = decode cmd item in
      Ok [ value ]

let decode_string_many cmd = decode_many decode_string_opt cmd
let decode_int_many cmd = decode_many decode_int_opt cmd
let decode_bool_many cmd = decode_many decode_bool_opt cmd

let decode_mget = function
  | R.Array items ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
            let* value = decode_string_opt "JSON.MGET" item in
            loop (value :: acc) rest
      in
      loop [] items
  | reply -> Error (protocol_violation "JSON.MGET" reply)

let decode_string_list cmd items =
  let rec loop acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest ->
        let* value = string_of_resp cmd item in
        loop (value :: acc) rest
  in
  loop [] items

let decode_obj_keys = function
  | R.Null -> Ok [ None ]
  | R.Array items ->
      let enhanced =
        items = []
        || List.exists
          (function R.Array _ | R.Null -> true | _ -> false)
          items
      in
      if enhanced then
        let rec loop acc = function
          | [] -> Ok (List.rev acc)
          | R.Null :: rest -> loop (None :: acc) rest
          | R.Array keys :: rest ->
              let* keys = decode_string_list "JSON.OBJKEYS" keys in
              loop (Some keys :: acc) rest
          | item :: _ -> Error (protocol_violation "JSON.OBJKEYS" item)
        in
        loop [] items
      else
        let* keys = decode_string_list "JSON.OBJKEYS" items in
        Ok [ Some keys ]
  | reply -> Error (protocol_violation "JSON.OBJKEYS" reply)

let get_format_args { indent; newline; space; no_escape } =
  let opt name = function
    | None -> []
    | Some value -> [ name; value ]
  in
  opt "INDENT" indent
  @ opt "NEWLINE" newline
  @ opt "SPACE" space
  @ if no_escape then [ "NOESCAPE" ] else []

let condition_arg = function
  | None -> []
  | Some If_missing -> [ "NX" ]
  | Some If_exists -> [ "XX" ]

let set_args ?condition ?(path = "$") ~key json =
  Array.of_list
    ([ "JSON.SET"; key; path; json ] @ condition_arg condition)

let get_args ~format ~key ~paths =
  Array.of_list
    ([ "JSON.GET"; key ] @ get_format_args format @ paths)

let mget_args ~keys ~path =
  Array.of_list (("JSON.MGET" :: keys) @ [ path ])

let arr_append_args ~key ~path json_values =
  Array.of_list ([ "JSON.ARRAPPEND"; key; path ] @ json_values)

let set ?timeout ?condition ?path client ~key json =
  expect_set
    (write_key ?timeout client key (set_args ?condition ?path ~key json))

let get ?timeout ?read_from ?(format = default_get_format)
    ?(paths = []) client ~key =
  match
    read_key ?timeout ?read_from client key
      (get_args ~format ~key ~paths)
  with
  | Error e -> Error e
  | Ok reply -> decode_string_opt "JSON.GET" reply

let ensure_non_empty what = function
  | [] -> invalid_arg (what ^ ": empty list")
  | xs -> xs

let mget ?timeout ?read_from client ~keys ~path =
  let keys = ensure_non_empty "Json.mget" keys in
  let first = List.hd keys in
  match
    read_key ?timeout ?read_from client first (mget_args ~keys ~path)
  with
  | Error e -> Error e
  | Ok reply -> decode_mget reply

let mset ?timeout client entries =
  let entries = ensure_non_empty "Json.mset" entries in
  let first = (List.hd entries).key in
  let entry_args { key; path; json } = [ key; path; json ] in
  expect_ok "JSON.MSET"
    (write_key ?timeout client first
       (Array.of_list
          ("JSON.MSET" :: List.concat_map entry_args entries)))

let key_path_args cmd key = function
  | None -> [| cmd; key |]
  | Some path -> [| cmd; key; path |]

let del ?timeout ?path client ~key =
  int_of_reply "JSON.DEL"
    (write_key ?timeout client key (key_path_args "JSON.DEL" key path))

let forget ?timeout ?path client ~key =
  int_of_reply "JSON.FORGET"
    (write_key ?timeout client key (key_path_args "JSON.FORGET" key path))

let clear ?timeout ?path client ~key =
  int_of_reply "JSON.CLEAR"
    (write_key ?timeout client key (key_path_args "JSON.CLEAR" key path))

let number_arg n = Printf.sprintf "%.17g" n

let number_op ?timeout client ~cmd ~key ~path number =
  match
    write_key ?timeout client key [| cmd; key; path; number_arg number |]
  with
  | Error e -> Error e
  | Ok reply -> decode_string_opt cmd reply

let num_incr_by ?timeout client ~key ~path number =
  number_op ?timeout client ~cmd:"JSON.NUMINCRBY" ~key ~path number

let num_mult_by ?timeout client ~key ~path number =
  number_op ?timeout client ~cmd:"JSON.NUMMULTBY" ~key ~path number

let write_json_values ?timeout client ~what ~cmd ~key ~path json_values =
  let json_values = ensure_non_empty what json_values in
  match
    write_key ?timeout client key
      (Array.of_list ([ cmd; key; path ] @ json_values))
  with
  | Error e -> Error e
  | Ok reply -> decode_int_many cmd reply

let arr_append ?timeout client ~key ~path json_values =
  write_json_values ?timeout client ~what:"Json.arr_append"
    ~cmd:"JSON.ARRAPPEND" ~key ~path json_values

let arr_insert ?timeout client ~key ~path ~index json_values =
  let json_values = ensure_non_empty "Json.arr_insert" json_values in
  match
    write_key ?timeout client key
      (Array.of_list
         ([ "JSON.ARRINSERT"; key; path; string_of_int index ]
          @ json_values))
  with
  | Error e -> Error e
  | Ok reply -> decode_int_many "JSON.ARRINSERT" reply

let arr_len ?timeout ?read_from ?path client ~key =
  match
    read_key ?timeout ?read_from client key
      (key_path_args "JSON.ARRLEN" key path)
  with
  | Error e -> Error e
  | Ok reply -> decode_int_many "JSON.ARRLEN" reply

let arr_pop ?timeout ?path ?index client ~key =
  let args =
    match path, index with
    | None, None -> [ "JSON.ARRPOP"; key ]
    | Some path, None -> [ "JSON.ARRPOP"; key; path ]
    | None, Some index -> [ "JSON.ARRPOP"; key; "$"; string_of_int index ]
    | Some path, Some index ->
        [ "JSON.ARRPOP"; key; path; string_of_int index ]
  in
  match write_key ?timeout client key (Array.of_list args) with
  | Error e -> Error e
  | Ok reply -> decode_string_many "JSON.ARRPOP" reply

let arr_trim ?timeout client ~key ~path ~start ~stop =
  match
    write_key ?timeout client key
      [| "JSON.ARRTRIM"; key; path; string_of_int start;
         string_of_int stop |]
  with
  | Error e -> Error e
  | Ok reply -> decode_int_many "JSON.ARRTRIM" reply

let arr_index ?timeout ?read_from ?start ?stop client ~key ~path ~json =
  let range =
    match start, stop with
    | None, None -> []
    | Some start, None -> [ string_of_int start ]
    | Some start, Some stop -> [ string_of_int start; string_of_int stop ]
    | None, Some _ ->
        invalid_arg "Json.arr_index: stop requires start"
  in
  match
    read_key ?timeout ?read_from client key
      (Array.of_list ([ "JSON.ARRINDEX"; key; path; json ] @ range))
  with
  | Error e -> Error e
  | Ok reply -> decode_int_many "JSON.ARRINDEX" reply

let strlen ?timeout ?read_from ?path client ~key =
  match
    read_key ?timeout ?read_from client key
      (key_path_args "JSON.STRLEN" key path)
  with
  | Error e -> Error e
  | Ok reply -> decode_int_many "JSON.STRLEN" reply

let str_append ?timeout ?path client ~key json =
  let args =
    match path with
    | None -> [| "JSON.STRAPPEND"; key; json |]
    | Some path -> [| "JSON.STRAPPEND"; key; path; json |]
  in
  match write_key ?timeout client key args with
  | Error e -> Error e
  | Ok reply -> decode_int_many "JSON.STRAPPEND" reply

let toggle ?timeout client ~key ~path =
  match write_key ?timeout client key [| "JSON.TOGGLE"; key; path |] with
  | Error e -> Error e
  | Ok reply -> decode_bool_many "JSON.TOGGLE" reply

let type_of ?timeout ?read_from ?path client ~key =
  match
    read_key ?timeout ?read_from client key
      (key_path_args "JSON.TYPE" key path)
  with
  | Error e -> Error e
  | Ok reply -> decode_string_many "JSON.TYPE" reply

let obj_len ?timeout ?read_from ?path client ~key =
  match
    read_key ?timeout ?read_from client key
      (key_path_args "JSON.OBJLEN" key path)
  with
  | Error e -> Error e
  | Ok reply -> decode_int_many "JSON.OBJLEN" reply

let obj_keys ?timeout ?read_from ?path client ~key =
  match
    read_key ?timeout ?read_from client key
      (key_path_args "JSON.OBJKEYS" key path)
  with
  | Error e -> Error e
  | Ok reply -> decode_obj_keys reply

let resp ?timeout ?read_from ?path client ~key =
  read_key ?timeout ?read_from client key
    (key_path_args "JSON.RESP" key path)

module For_testing = struct
  let set_args = set_args
  let get_args = get_args
  let mget_args = mget_args
  let arr_append_args = arr_append_args
  let decode_get reply = decode_string_opt "JSON.GET" reply
  let decode_mget = decode_mget
  let decode_type reply = decode_string_many "JSON.TYPE" reply
  let decode_int_results = decode_int_many
  let decode_bool_results = decode_bool_many
  let decode_obj_keys = decode_obj_keys
end
