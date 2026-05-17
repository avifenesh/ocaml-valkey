module R = Resp3
module E = Connection.Error

type scaling =
  | Default_scaling
  | Expansion of int
  | Non_scaling

type insert_options = {
  capacity : int option;
  error_rate : float option;
  scaling : scaling;
  seed : string option;
  tightening : float option;
  validate_scale_to : int option;
  no_create : bool;
}

let default_insert_options =
  { capacity = None;
    error_rate = None;
    scaling = Default_scaling;
    seed = None;
    tightening = None;
    validate_scale_to = None;
    no_create = false;
  }

type info = {
  capacity : int;
  size : int;
  filters : int;
  items : int;
  error_rate : float;
  expansion : int option;
  tightening : float option;
  max_scaled_capacity : int option;
  raw : (string * Resp3.t) list;
}

type info_selector =
  | Capacity
  | Size
  | Filters
  | Items
  | Error_rate
  | Expansion_rate
  | Tightening_ratio
  | Max_scaled_capacity

type info_value =
  | Int of int
  | Float of float
  | Not_applicable

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

let string_of_float f = Printf.sprintf "%.17g" f

let int_of_int64 cmd n =
  let min = Int64.of_int min_int in
  let max = Int64.of_int max_int in
  if Int64.compare n min < 0 || Int64.compare n max > 0 then
    Error
      (E.Protocol_violation
         (cmd ^ ": integer reply out of OCaml int range: "
          ^ Int64.to_string n))
  else Ok (Int64.to_int n)

let int_of_resp cmd = function
  | R.Integer n -> int_of_int64 cmd n
  | v -> Error (protocol_violation cmd v)

let int_of_reply cmd = function
  | Ok v -> int_of_resp cmd v
  | Error e -> Error e

let string_of_resp cmd = function
  | R.Bulk_string s | R.Simple_string s
  | R.Verbatim_string { data = s; _ } -> Ok s
  | v -> Error (protocol_violation cmd v)

let float_of_resp cmd = function
  | R.Double f -> Ok f
  | R.Bulk_string s | R.Simple_string s
  | R.Verbatim_string { data = s; _ } ->
      (try Ok (float_of_string s) with Failure _ ->
         Error (protocol_violation cmd (R.Bulk_string s)))
  | R.Integer n -> Ok (Int64.to_float n)
  | v -> Error (protocol_violation cmd v)

let bool_of_resp cmd = function
  | R.Boolean b -> Ok b
  | R.Integer 0L -> Ok false
  | R.Integer 1L -> Ok true
  | v -> Error (protocol_violation cmd v)

let bool_of_reply cmd = function
  | Ok v -> bool_of_resp cmd v
  | Error e -> Error e

let decode_bools cmd = function
  | R.Array items ->
      let rec loop acc = function
        | [] -> Ok (List.rev acc)
        | item :: rest ->
            let* value = bool_of_resp cmd item in
            loop (value :: acc) rest
      in
      loop [] items
  | v -> Error (protocol_violation cmd v)

let expect_ok cmd = function
  | Ok (R.Simple_string "OK") | Ok (R.Bulk_string "OK") -> Ok ()
  | Ok v -> Error (protocol_violation cmd v)
  | Error e -> Error e

let ensure_non_empty what = function
  | [] -> invalid_arg (what ^ ": empty list")
  | xs -> xs

let opt_arg name to_string = function
  | None -> []
  | Some v -> [ name; to_string v ]

let bool_arg name enabled = if enabled then [ name ] else []

let scaling_args = function
  | Default_scaling -> []
  | Expansion expansion -> [ "EXPANSION"; string_of_int expansion ]
  | Non_scaling -> [ "NONSCALING" ]

let reserve_args ~scaling ~key ~error_rate ~capacity =
  Array.of_list
    ([ "BF.RESERVE"; key; string_of_float error_rate; string_of_int capacity ]
     @ scaling_args scaling)

let validate_insert_options options =
  match options.scaling, options.validate_scale_to with
  | Non_scaling, Some _ ->
      invalid_arg
        "Bloom.insert: Non_scaling and validate_scale_to are mutually exclusive"
  | _ -> ()

let insert_args ~options ~key ~items =
  validate_insert_options options;
  let item_args =
    match items with
    | [] -> []
    | items -> "ITEMS" :: items
  in
  Array.of_list
    ([ "BF.INSERT"; key ]
     @ opt_arg "CAPACITY" string_of_int options.capacity
     @ opt_arg "ERROR" string_of_float options.error_rate
     @ scaling_args options.scaling
     @ opt_arg "SEED" Fun.id options.seed
     @ opt_arg "TIGHTENING" string_of_float options.tightening
     @ opt_arg "VALIDATESCALETO" string_of_int options.validate_scale_to
     @ bool_arg "NOCREATE" options.no_create
     @ item_args)

let info_selector_arg = function
  | Capacity -> "CAPACITY"
  | Size -> "SIZE"
  | Filters -> "FILTERS"
  | Items -> "ITEMS"
  | Error_rate -> "ERROR"
  | Expansion_rate -> "EXPANSION"
  | Tightening_ratio -> "TIGHTENING"
  | Max_scaled_capacity -> "MAXSCALEDCAPACITY"

let info_args ?selector ~key () =
  match selector with
  | None -> [| "BF.INFO"; key |]
  | Some selector -> [| "BF.INFO"; key; info_selector_arg selector |]

let reserve ?timeout ?(scaling = Default_scaling)
    client ~key ~error_rate ~capacity =
  expect_ok "BF.RESERVE"
    (write_key ?timeout client key
       (reserve_args ~scaling ~key ~error_rate ~capacity))

let add ?timeout client ~key value =
  bool_of_reply "BF.ADD"
    (write_key ?timeout client key [| "BF.ADD"; key; value |])

let madd ?timeout client ~key values =
  let values = ensure_non_empty "Bloom.madd" values in
  match
    write_key ?timeout client key
      (Array.of_list ("BF.MADD" :: key :: values))
  with
  | Error e -> Error e
  | Ok reply -> decode_bools "BF.MADD" reply

let exists ?timeout ?read_from client ~key value =
  bool_of_reply "BF.EXISTS"
    (read_key ?timeout ?read_from client key
       [| "BF.EXISTS"; key; value |])

let mexists ?timeout ?read_from client ~key values =
  let values = ensure_non_empty "Bloom.mexists" values in
  match
    read_key ?timeout ?read_from client key
      (Array.of_list ("BF.MEXISTS" :: key :: values))
  with
  | Error e -> Error e
  | Ok reply -> decode_bools "BF.MEXISTS" reply

let insert ?timeout ?(options = default_insert_options)
    ?(items = []) client ~key =
  match
    write_key ?timeout client key (insert_args ~options ~key ~items)
  with
  | Error e -> Error e
  | Ok reply -> decode_bools "BF.INSERT" reply

let card ?timeout ?read_from client ~key =
  int_of_reply "BF.CARD"
    (read_key ?timeout ?read_from client key [| "BF.CARD"; key |])

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

let decode_info_raw = decode_pairs "BF.INFO"

let find_field names pairs =
  List.find_map
    (fun (name, value) ->
      if List.mem name names then Some value else None)
    pairs

let missing_info_field name =
  E.Protocol_violation ("BF.INFO: missing field " ^ name)

let required name names decode pairs =
  match find_field names pairs with
  | None -> Error (missing_info_field name)
  | Some value -> decode value

let optional _name names decode pairs =
  match find_field names pairs with
  | None | Some R.Null -> Ok None
  | Some value ->
      let* value = decode value in
      Ok (Some value)

let decode_info reply =
  let* raw = decode_info_raw reply in
  let int name names =
    required name names (int_of_resp ("BF.INFO " ^ name)) raw
  in
  let float name names =
    required name names (float_of_resp ("BF.INFO " ^ name)) raw
  in
  let opt_int name names =
    optional name names (int_of_resp ("BF.INFO " ^ name)) raw
  in
  let opt_float name names =
    optional name names (float_of_resp ("BF.INFO " ^ name)) raw
  in
  let* capacity = int "Capacity" [ "Capacity" ] in
  let* size = int "Size" [ "Size" ] in
  let* filters = int "Number of filters" [ "Number of filters"; "Filters" ] in
  let* items =
    int "Number of items inserted"
      [ "Number of items inserted"; "Items" ]
  in
  let* error_rate = float "Error rate" [ "Error rate"; "Error" ] in
  let* expansion =
    opt_int "Expansion rate" [ "Expansion rate"; "Expansion" ]
  in
  let* tightening =
    opt_float "Tightening ratio" [ "Tightening ratio"; "Tightening" ]
  in
  let* max_scaled_capacity =
    opt_int "Max scaled capacity"
      [ "Max scaled capacity"; "Max scaled capacity "; "MAXSCALEDCAPACITY" ]
  in
  Ok
    { capacity;
      size;
      filters;
      items;
      error_rate;
      expansion;
      tightening;
      max_scaled_capacity;
      raw;
    }

let info_raw ?timeout ?read_from client ~key =
  match read_key ?timeout ?read_from client key (info_args ~key ()) with
  | Error e -> Error e
  | Ok reply -> decode_info_raw reply

let info ?timeout ?read_from client ~key =
  match read_key ?timeout ?read_from client key (info_args ~key ()) with
  | Error e -> Error e
  | Ok reply -> decode_info reply

let decode_info_value selector reply =
  match reply with
  | R.Null -> Ok Not_applicable
  | _ ->
      (match selector with
       | Error_rate | Tightening_ratio ->
           let* value =
             float_of_resp ("BF.INFO " ^ info_selector_arg selector) reply
           in
           Ok (Float value)
       | Capacity | Size | Filters | Items | Expansion_rate
       | Max_scaled_capacity ->
           let* value =
             int_of_resp ("BF.INFO " ^ info_selector_arg selector) reply
           in
           Ok (Int value))

let info_value ?timeout ?read_from client ~key selector =
  match
    read_key ?timeout ?read_from client key
      (info_args ~selector ~key ())
  with
  | Error e -> Error e
  | Ok reply -> decode_info_value selector reply

let load ?timeout client ~key ~dump =
  expect_ok "BF.LOAD"
    (write_key ?timeout client key [| "BF.LOAD"; key; dump |])

module For_testing = struct
  let reserve_args = reserve_args
  let insert_args = insert_args
  let info_args = info_args
  let decode_bools = decode_bools
  let decode_info_raw = decode_info_raw
  let decode_info = decode_info
  let decode_info_value = decode_info_value
end
