module C = Valkey.Client
module J = Valkey.Json
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let key = "example:json:user:1"
let key2 = "example:json:user:2"
let key3 = "example:json:user:3"

let fail_conn label e =
  Format.eprintf "%s: %a@." label E.pp e;
  exit 1

let expect label = function
  | Ok v -> v
  | Error e -> fail_conn label e

let expect_set label result =
  match expect label result with
  | true -> ()
  | false ->
      Format.eprintf "%s: condition prevented write@." label;
      exit 1

let print_string_options label xs =
  let values =
    xs
    |> List.map (function None -> "null" | Some s -> s)
    |> String.concat ", "
  in
  Printf.printf "%s: [%s]\n" label values

let print_int_options label xs =
  let values =
    xs
    |> List.map (function None -> "null" | Some n -> string_of_int n)
    |> String.concat ", "
  in
  Printf.printf "%s: [%s]\n" label values

let print_bool_options label xs =
  let values =
    xs
    |> List.map (function
        | None -> "null"
        | Some true -> "true"
        | Some false -> "false")
    |> String.concat ", "
  in
  Printf.printf "%s: [%s]\n" label values

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6381 ()
  in
  Fun.protect ~finally:(fun () -> C.close client) @@ fun () ->

  ignore (J.del client ~key);
  ignore (J.del client ~key:key2);
  ignore (J.del client ~key:key3);

  expect_set "JSON.SET"
    (J.set client ~key
       "{\"name\":\"ada\",\"age\":36,\"tags\":[\"math\"],\
        \"active\":true,\"meta\":{\"country\":\"uk\"}}");
  expect_set "JSON.SET second"
    (J.set client ~key:key2 "{\"name\":\"grace\",\"age\":30}");

  (match expect "JSON.GET" (J.get client ~paths:[ "$.name"; "$.age" ] ~key) with
   | Some payload -> Printf.printf "selected fields: %s\n" payload
   | None -> Printf.printf "selected fields: <missing>\n");

  print_string_options "root type"
    (expect "JSON.TYPE" (J.type_of client ~path:"$" ~key));

  (match expect "JSON.OBJKEYS" (J.obj_keys client ~path:"$" ~key) with
   | Some keys :: _ -> Printf.printf "root keys: %s\n" (String.concat ", " keys)
   | None :: _ -> Printf.printf "root keys: <null>\n"
   | [] -> Printf.printf "root keys: <none>\n");

  print_int_options "root object length"
    (expect "JSON.OBJLEN" (J.obj_len client ~path:"$" ~key));

  print_int_options "array length after append"
    (expect "JSON.ARRAPPEND"
       (J.arr_append client ~key ~path:"$.tags" [ "\"logic\"" ]));
  print_int_options "array length after insert"
    (expect "JSON.ARRINSERT"
       (J.arr_insert client ~key ~path:"$.tags" ~index:1
          [ "\"poetry\"" ]));
  print_int_options "array index of poetry"
    (expect "JSON.ARRINDEX"
       (J.arr_index client ~key ~path:"$.tags" ~json:"\"poetry\""));
  print_string_options "array popped value"
    (expect "JSON.ARRPOP" (J.arr_pop client ~key ~path:"$.tags" ~index:1));
  print_int_options "array length after trim"
    (expect "JSON.ARRTRIM"
       (J.arr_trim client ~key ~path:"$.tags" ~start:0 ~stop:0));

  print_int_options "name length after append"
    (expect "JSON.STRAPPEND"
       (J.str_append client ~key ~path:"$.name" "\" lovelace\""));
  print_int_options "name length"
    (expect "JSON.STRLEN" (J.strlen client ~key ~path:"$.name"));

  (match
     expect "JSON.NUMINCRBY"
       (J.num_incr_by client ~key ~path:"$.age" 1.0)
   with
   | Some payload -> Printf.printf "age after increment: %s\n" payload
   | None -> Printf.printf "age after increment: <missing>\n");
  (match
     expect "JSON.NUMMULTBY"
       (J.num_mult_by client ~key ~path:"$.age" 2.0)
   with
   | Some payload -> Printf.printf "age after multiply: %s\n" payload
   | None -> Printf.printf "age after multiply: <missing>\n");

  print_bool_options "active after toggle"
    (expect "JSON.TOGGLE" (J.toggle client ~key ~path:"$.active"));

  expect "JSON.MSET"
    (J.mset client
       [ { J.key = key3;
           path = "$";
           json = "{\"name\":\"katherine\"}";
         };
       ]);

  let names =
    expect "JSON.MGET"
      (J.mget client ~path:"$.name"
         ~keys:[ key; key2; key3; "example:json:missing" ])
    |> List.map (function None -> "null" | Some s -> s)
    |> String.concat ", "
  in
  Printf.printf "names via mget: [%s]\n" names;

  (match expect "JSON.RESP" (J.resp client ~path:"$.name" ~key) with
   | R.Array _ -> Printf.printf "raw RESP view: <array>\n"
   | reply -> Format.printf "raw RESP view: %a@." R.pp reply);

  Printf.printf "forgot meta fields: %d\n"
    (expect "JSON.FORGET" (J.forget client ~key ~path:"$.meta"));
  Printf.printf "cleared tag arrays: %d\n"
    (expect "JSON.CLEAR" (J.clear client ~key ~path:"$.tags"));

  ignore (J.del client ~key);
  ignore (J.del client ~key:key2);
  ignore (J.del client ~key:key3)
