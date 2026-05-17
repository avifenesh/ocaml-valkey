module J = Valkey.Json
module R = Valkey.Resp3
module E = Valkey.Connection.Error
module C = Valkey.Client
module Router = Valkey.Router
module T = Valkey.Router.Target
module RF = Valkey.Router.Read_from

let array_check name expected actual =
  Alcotest.(check (list string)) name (Array.to_list expected)
    (Array.to_list actual)

let fake_client ?error ?(reply = R.Null) ?(read_from = RF.Primary) () =
  let seen = ref None in
  let exec ?timeout:_ target rf args =
    seen := Some (target, rf, Array.to_list args);
    match error with
    | Some e -> Error e
    | None -> Ok reply
  in
  let exec_multi ?timeout:_ _fan _args = [] in
  let pair ?timeout:_ _target _args1 _args2 =
    Error (E.Terminal "unused")
  in
  let router =
    Router.make ~exec ~exec_multi ~pair ~close:(fun () -> ())
      ~primary:(fun () -> None)
      ~connection_for_slot:(fun _ -> None)
      ~endpoint_for_slot:(fun _ -> None)
      ~endpoint_for_node:(fun ~node_id:_ -> None)
      ~all_connections:(fun () -> [])
      ~is_standalone:false
      ~atomic_lock_for_slot:(fun _ -> Eio.Mutex.create ())
  in
  let config = { C.Config.default with read_from } in
  (C.from_router ~config router, seen)

let check_seen name ~key ~read_from ~args seen =
  match !seen with
  | Some (T.By_slot s, rf, got)
    when s = Valkey.Slot.of_key key && rf = read_from && got = args ->
      ()
  | Some _ ->
      Alcotest.fail
        (name ^ " routed with unexpected target/read policy/args")
  | None -> Alcotest.fail (name ^ " did not call fake router")

let expect_invalid_arg name f =
  match f () with
  | exception Invalid_argument _ -> ()
  | _ -> Alcotest.fail (name ^ " should reject invalid input")

let expect_protocol_violation name = function
  | Error (E.Protocol_violation _) -> ()
  | Ok _ -> Alcotest.fail (name ^ " should reject the reply shape")
  | Error e -> Alcotest.failf "%s: expected protocol violation, got %a" name E.pp e

let expect_terminal name = function
  | Error (E.Terminal "wire closed") -> ()
  | Ok _ -> Alcotest.fail (name ^ " should pass through transport errors")
  | Error e -> Alcotest.failf "%s: unexpected transport error %a" name E.pp e

let test_set_args () =
  let args =
    J.For_testing.set_args ~path:"$.profile"
      ~condition:J.If_missing ~key:"user:1"
      "{\"name\":\"ada\"}"
  in
  array_check "JSON.SET args"
    [| "JSON.SET"; "user:1"; "$.profile"; "{\"name\":\"ada\"}"; "NX" |]
    args

let test_get_args_with_format () =
  let format : J.get_format =
    { indent = Some "  ";
      newline = Some "\n";
      space = Some " ";
      no_escape = true;
    }
  in
  let args =
    J.For_testing.get_args ~format
      ~paths:[ "$.name"; "$.age" ] ~key:"user:1"
  in
  array_check "JSON.GET args"
    [| "JSON.GET"; "user:1";
       "INDENT"; "  ";
       "NEWLINE"; "\n";
       "SPACE"; " ";
       "NOESCAPE";
       "$.name"; "$.age";
    |]
    args

let test_mget_args () =
  let args =
    J.For_testing.mget_args ~path:"$.name"
      ~keys:[ "user:{1}:a"; "user:{1}:b" ]
  in
  array_check "JSON.MGET args"
    [| "JSON.MGET"; "user:{1}:a"; "user:{1}:b"; "$.name" |]
    args

let test_arr_append_args () =
  let args =
    J.For_testing.arr_append_args ~path:"$.tags" ~key:"user:1"
      [ "\"math\""; "\"logic\"" ]
  in
  array_check "JSON.ARRAPPEND args"
    [| "JSON.ARRAPPEND"; "user:1"; "$.tags"; "\"math\""; "\"logic\"" |]
    args

let test_set_conditions_and_reply_shapes () =
  let args =
    J.For_testing.set_args ~condition:J.If_exists ~key:"user:1"
      "{\"name\":\"ada\"}"
  in
  array_check "JSON.SET XX args"
    [| "JSON.SET"; "user:1"; "$"; "{\"name\":\"ada\"}"; "XX" |]
    args;
  let client, seen = fake_client ~reply:R.Null () in
  (match J.set client ~condition:J.If_exists ~key:"user:1" "{}" with
   | Ok false -> ()
   | Ok true -> Alcotest.fail "JSON.SET condition should return false"
   | Error e -> Alcotest.failf "JSON.SET conditional: %a" E.pp e);
  check_seen "JSON.SET XX" ~key:"user:1" ~read_from:RF.Primary
    ~args:[ "JSON.SET"; "user:1"; "$"; "{}"; "XX" ] seen;
  let client, _seen = fake_client ~reply:(R.Integer 1L) () in
  expect_protocol_violation "JSON.SET bad reply"
    (J.set client ~key:"user:1" "{}")

let test_mset_args_and_empty_input () =
  let key = "json:{1}:a" in
  let client, seen = fake_client ~reply:(R.Simple_string "OK") () in
  (match
     J.mset client
       [ { J.key; path = "$"; json = "{\"name\":\"ada\"}" };
         { J.key = "json:{1}:b";
           path = "$.profile";
           json = "{\"active\":true}";
         };
       ]
   with
   | Ok () -> ()
   | Error e -> Alcotest.failf "JSON.MSET: %a" E.pp e);
  check_seen "JSON.MSET" ~key ~read_from:RF.Primary
    ~args:
      [ "JSON.MSET";
        "json:{1}:a";
        "$";
        "{\"name\":\"ada\"}";
        "json:{1}:b";
        "$.profile";
        "{\"active\":true}";
      ]
    seen;
  expect_invalid_arg "JSON.MSET empty" (fun () ->
      ignore (J.mset client []));
  let client, _seen = fake_client ~reply:R.Null () in
  expect_protocol_violation "JSON.MSET bad reply"
    (J.mset client
       [ { J.key = key; path = "$"; json = "{\"name\":\"ada\"}" } ])

let test_key_path_and_number_commands () =
  let key = "json:1" in
  let client, seen = fake_client ~reply:(R.Integer 1L) () in
  (match J.forget client ~key ~path:"$.stale" with
   | Ok 1 -> ()
   | Ok n -> Alcotest.failf "unexpected JSON.FORGET count %d" n
   | Error e -> Alcotest.failf "JSON.FORGET: %a" E.pp e);
  check_seen "JSON.FORGET" ~key ~read_from:RF.Primary
    ~args:[ "JSON.FORGET"; key; "$.stale" ] seen;

  let client, seen = fake_client ~reply:(R.Integer 2L) () in
  (match J.clear client ~key with
   | Ok 2 -> ()
   | Ok n -> Alcotest.failf "unexpected JSON.CLEAR count %d" n
   | Error e -> Alcotest.failf "JSON.CLEAR: %a" E.pp e);
  check_seen "JSON.CLEAR" ~key ~read_from:RF.Primary
    ~args:[ "JSON.CLEAR"; key ] seen;

  let client, seen = fake_client ~reply:(R.Bulk_string "[74]") () in
  (match J.num_mult_by client ~key ~path:"$.age" 2.0 with
   | Ok (Some "[74]") -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.NUMMULTBY payload"
   | Error e -> Alcotest.failf "JSON.NUMMULTBY: %a" E.pp e);
  check_seen "JSON.NUMMULTBY" ~key ~read_from:RF.Primary
    ~args:[ "JSON.NUMMULTBY"; key; "$.age"; "2" ] seen

let test_protocol_violations_and_errors () =
  let key = "json:1" in
  let transport = E.Terminal "wire closed" in
  let client, _seen = fake_client ~error:transport () in
  (match J.get client ~key with
   | Error (E.Terminal "wire closed") -> ()
   | Ok _ -> Alcotest.fail "JSON.GET should pass through transport error"
   | Error e -> Alcotest.failf "unexpected transport error %a" E.pp e);

  let client, _seen = fake_client ~reply:(R.Bulk_string "not-int") () in
  expect_protocol_violation "JSON.DEL bad reply" (J.del client ~key);

  let client, _seen = fake_client ~reply:(R.Integer 2L) () in
  expect_protocol_violation "JSON.NUMINCRBY bad reply"
    (J.num_incr_by client ~key ~path:"$.age" 1.0);

  let client, _seen = fake_client ~reply:(R.Array [ R.Integer 2L ]) () in
  expect_protocol_violation "JSON.TOGGLE bad bool"
    (J.toggle client ~key ~path:"$.active")

let test_array_commands () =
  let key = "json:1" in
  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 3L ]) ()
  in
  (match
     J.arr_insert client ~key ~path:"$.tags" ~index:1
       [ "\"logic\"" ]
   with
   | Ok [ Some 3 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRINSERT result"
   | Error e -> Alcotest.failf "JSON.ARRINSERT: %a" E.pp e);
  check_seen "JSON.ARRINSERT" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRINSERT"; key; "$.tags"; "1"; "\"logic\"" ]
    seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Bulk_string "\"logic\"" ]) ()
  in
  (match J.arr_pop client ~key ~path:"$.tags" ~index:1 with
   | Ok [ Some "\"logic\"" ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRPOP result"
   | Error e -> Alcotest.failf "JSON.ARRPOP: %a" E.pp e);
  check_seen "JSON.ARRPOP" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRPOP"; key; "$.tags"; "1" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 1L ]) ()
  in
  (match J.arr_trim client ~key ~path:"$.tags" ~start:0 ~stop:0 with
   | Ok [ Some 1 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRTRIM result"
   | Error e -> Alcotest.failf "JSON.ARRTRIM: %a" E.pp e);
  check_seen "JSON.ARRTRIM" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRTRIM"; key; "$.tags"; "0"; "0" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 0L ])
      ~read_from:RF.Prefer_replica ()
  in
  (match
     J.arr_index client ~key ~path:"$.tags" ~json:"\"math\""
       ~start:0 ~stop:2
   with
   | Ok [ Some 0 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRINDEX result"
   | Error e -> Alcotest.failf "JSON.ARRINDEX: %a" E.pp e);
  check_seen "JSON.ARRINDEX" ~key ~read_from:RF.Prefer_replica
    ~args:[ "JSON.ARRINDEX"; key; "$.tags"; "\"math\""; "0"; "2" ]
    seen;

  expect_invalid_arg "JSON.ARRAPPEND empty" (fun () ->
      ignore (J.arr_append client ~key ~path:"$.tags" []));
  expect_invalid_arg "JSON.ARRINSERT empty" (fun () ->
      ignore (J.arr_insert client ~key ~path:"$.tags" ~index:0 []));
  expect_invalid_arg "JSON.ARRINDEX stop without start" (fun () ->
      ignore
        (J.arr_index client ~key ~path:"$.tags" ~json:"\"math\""
           ~stop:2))

let test_array_argument_variants () =
  let key = "json:1" in
  let client, seen =
    fake_client ~reply:(R.Array [ R.Bulk_string "\"tail\"" ]) ()
  in
  (match J.arr_pop client ~key with
   | Ok [ Some "\"tail\"" ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRPOP default result"
   | Error e -> Alcotest.failf "JSON.ARRPOP default: %a" E.pp e);
  check_seen "JSON.ARRPOP default" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRPOP"; key ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Bulk_string "\"tail\"" ]) ()
  in
  (match J.arr_pop client ~key ~path:"$.tags" with
   | Ok [ Some "\"tail\"" ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRPOP path result"
   | Error e -> Alcotest.failf "JSON.ARRPOP path: %a" E.pp e);
  check_seen "JSON.ARRPOP path" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRPOP"; key; "$.tags" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Bulk_string "\"head\"" ]) ()
  in
  (match J.arr_pop client ~key ~index:0 with
   | Ok [ Some "\"head\"" ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRPOP index result"
   | Error e -> Alcotest.failf "JSON.ARRPOP index: %a" E.pp e);
  check_seen "JSON.ARRPOP index" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRPOP"; key; "$"; "0" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 1L ]) ()
  in
  (match J.arr_index client ~key ~path:"$.tags" ~json:"\"logic\"" with
   | Ok [ Some 1 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRINDEX no range result"
   | Error e -> Alcotest.failf "JSON.ARRINDEX no range: %a" E.pp e);
  check_seen "JSON.ARRINDEX no range" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRINDEX"; key; "$.tags"; "\"logic\"" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 1L ]) ()
  in
  (match
     J.arr_index client ~key ~path:"$.tags" ~json:"\"logic\"" ~start:1
   with
   | Ok [ Some 1 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRINDEX start result"
   | Error e -> Alcotest.failf "JSON.ARRINDEX start: %a" E.pp e);
  check_seen "JSON.ARRINDEX start" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRINDEX"; key; "$.tags"; "\"logic\""; "1" ] seen

let test_string_object_and_resp_commands () =
  let key = "json:1" in
  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 12L ]) ()
  in
  (match J.strlen client ~key ~path:"$.name" with
   | Ok [ Some 12 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.STRLEN result"
   | Error e -> Alcotest.failf "JSON.STRLEN: %a" E.pp e);
  check_seen "JSON.STRLEN" ~key ~read_from:RF.Primary
    ~args:[ "JSON.STRLEN"; key; "$.name" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 13L ]) ()
  in
  (match J.str_append client ~key "\"!\"" with
   | Ok [ Some 13 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.STRAPPEND result"
   | Error e -> Alcotest.failf "JSON.STRAPPEND: %a" E.pp e);
  check_seen "JSON.STRAPPEND" ~key ~read_from:RF.Primary
    ~args:[ "JSON.STRAPPEND"; key; "\"!\"" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 5L ])
      ~read_from:RF.Prefer_replica ()
  in
  (match J.obj_len client ~key ~path:"$" with
   | Ok [ Some 5 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.OBJLEN result"
   | Error e -> Alcotest.failf "JSON.OBJLEN: %a" E.pp e);
  check_seen "JSON.OBJLEN" ~key ~read_from:RF.Prefer_replica
    ~args:[ "JSON.OBJLEN"; key; "$" ] seen;

  let raw = R.Array [ R.Simple_string "{"; R.Simple_string "}" ] in
  let client, seen = fake_client ~reply:raw () in
  (match J.resp client ~key ~path:"$" with
   | Ok reply when R.equal reply raw -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.RESP reply"
   | Error e -> Alcotest.failf "JSON.RESP: %a" E.pp e);
  check_seen "JSON.RESP" ~key ~read_from:RF.Primary
    ~args:[ "JSON.RESP"; key; "$" ] seen

let test_read_overrides_and_scalar_decodes () =
  let key = "json:1" in
  let read_from = RF.Az_affinity { az = "us-east-1a" } in
  let client, seen = fake_client ~reply:(R.Integer 7L) () in
  (match J.arr_len client ~read_from ~key with
   | Ok [ Some 7 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRLEN scalar result"
   | Error e -> Alcotest.failf "JSON.ARRLEN scalar: %a" E.pp e);
  check_seen "JSON.ARRLEN override" ~key ~read_from
    ~args:[ "JSON.ARRLEN"; key ] seen;

  let client, seen = fake_client ~reply:(R.Simple_string "string") () in
  (match J.type_of client ~read_from ~key with
   | Ok [ Some "string" ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.TYPE scalar result"
   | Error e -> Alcotest.failf "JSON.TYPE scalar: %a" E.pp e);
  check_seen "JSON.TYPE override" ~key ~read_from
    ~args:[ "JSON.TYPE"; key ] seen

let test_reply_variants () =
  let key = "json:1" in
  let client, seen = fake_client ~reply:(R.Bulk_string "OK") () in
  (match J.set client ~key "{}" with
   | Ok true -> ()
   | Ok false -> Alcotest.fail "JSON.SET bulk OK returned false"
   | Error e -> Alcotest.failf "JSON.SET bulk OK: %a" E.pp e);
  check_seen "JSON.SET bulk OK" ~key ~read_from:RF.Primary
    ~args:[ "JSON.SET"; key; "$"; "{}" ] seen;

  let client, seen = fake_client ~reply:(R.Bulk_string "OK") () in
  (match J.mset client [ { J.key = key; path = "$"; json = "{}" } ] with
   | Ok () -> ()
   | Error e -> Alcotest.failf "JSON.MSET bulk OK: %a" E.pp e);
  check_seen "JSON.MSET bulk OK" ~key ~read_from:RF.Primary
    ~args:[ "JSON.MSET"; key; "$"; "{}" ] seen;

  let client, seen =
    fake_client
      ~reply:(R.Verbatim_string { encoding = "txt"; data = "{\"v\":1}" })
      ()
  in
  (match J.get client ~key with
   | Ok (Some "{\"v\":1}") -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.GET verbatim payload"
   | Error e -> Alcotest.failf "JSON.GET verbatim: %a" E.pp e);
  check_seen "JSON.GET verbatim" ~key ~read_from:RF.Primary
    ~args:[ "JSON.GET"; key ] seen;

  let client, seen = fake_client ~reply:(R.Array [ R.Integer 2L ]) () in
  (match J.arr_append client ~key ~path:"$.items" [ "1" ] with
   | Ok [ Some 2 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRAPPEND result"
   | Error e -> Alcotest.failf "JSON.ARRAPPEND: %a" E.pp e);
  check_seen "JSON.ARRAPPEND" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRAPPEND"; key; "$.items"; "1" ] seen;

  let client, seen = fake_client ~reply:R.Null () in
  (match J.arr_pop client ~key with
   | Ok [ None ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRPOP null result"
   | Error e -> Alcotest.failf "JSON.ARRPOP null: %a" E.pp e);
  check_seen "JSON.ARRPOP null" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRPOP"; key ] seen;

  let client, seen = fake_client ~reply:(R.Integer 0L) () in
  (match J.arr_trim client ~key ~path:"$.items" ~start:0 ~stop:0 with
   | Ok [ Some 0 ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.ARRTRIM scalar result"
   | Error e -> Alcotest.failf "JSON.ARRTRIM scalar: %a" E.pp e);
  check_seen "JSON.ARRTRIM scalar" ~key ~read_from:RF.Primary
    ~args:[ "JSON.ARRTRIM"; key; "$.items"; "0"; "0" ] seen;

  let client, seen = fake_client ~reply:(R.Boolean false) () in
  (match J.toggle client ~key ~path:"$.flag" with
   | Ok [ Some false ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.TOGGLE scalar bool result"
   | Error e -> Alcotest.failf "JSON.TOGGLE scalar bool: %a" E.pp e);
  check_seen "JSON.TOGGLE scalar bool" ~key ~read_from:RF.Primary
    ~args:[ "JSON.TOGGLE"; key; "$.flag" ] seen;

  let client, seen = fake_client ~reply:R.Null () in
  (match J.type_of client ~key with
   | Ok [ None ] -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.TYPE null result"
   | Error e -> Alcotest.failf "JSON.TYPE null: %a" E.pp e);
  check_seen "JSON.TYPE null" ~key ~read_from:RF.Primary
    ~args:[ "JSON.TYPE"; key ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Bulk_string "name" ]) ()
  in
  (match J.obj_keys client ~key with
   | Ok [ Some [ "name" ] ] -> ()
   | Ok _ -> Alcotest.fail "unexpected restricted JSON.OBJKEYS result"
   | Error e -> Alcotest.failf "JSON.OBJKEYS restricted: %a" E.pp e);
  check_seen "JSON.OBJKEYS restricted" ~key ~read_from:RF.Primary
    ~args:[ "JSON.OBJKEYS"; key ] seen

let test_transport_errors () =
  let key = "json:1" in
  let client, _seen = fake_client ~error:(E.Terminal "wire closed") () in
  expect_terminal "JSON.SET" (J.set client ~key "{}");
  expect_terminal "JSON.GET" (J.get client ~key);
  expect_terminal "JSON.MGET" (J.mget client ~keys:[ key ] ~path:"$");
  expect_terminal "JSON.MSET"
    (J.mset client [ { J.key = key; path = "$"; json = "{}" } ]);
  expect_terminal "JSON.DEL" (J.del client ~key);
  expect_terminal "JSON.FORGET" (J.forget client ~key);
  expect_terminal "JSON.CLEAR" (J.clear client ~key);
  expect_terminal "JSON.NUMINCRBY"
    (J.num_incr_by client ~key ~path:"$.n" 1.0);
  expect_terminal "JSON.NUMMULTBY"
    (J.num_mult_by client ~key ~path:"$.n" 2.0);
  expect_terminal "JSON.ARRAPPEND"
    (J.arr_append client ~key ~path:"$.items" [ "1" ]);
  expect_terminal "JSON.ARRINSERT"
    (J.arr_insert client ~key ~path:"$.items" ~index:0 [ "1" ]);
  expect_terminal "JSON.ARRLEN" (J.arr_len client ~key);
  expect_terminal "JSON.ARRPOP" (J.arr_pop client ~key);
  expect_terminal "JSON.ARRTRIM"
    (J.arr_trim client ~key ~path:"$.items" ~start:0 ~stop:0);
  expect_terminal "JSON.ARRINDEX"
    (J.arr_index client ~key ~path:"$.items" ~json:"1");
  expect_terminal "JSON.STRLEN" (J.strlen client ~key);
  expect_terminal "JSON.STRAPPEND" (J.str_append client ~key "\"x\"");
  expect_terminal "JSON.TOGGLE" (J.toggle client ~key ~path:"$.flag");
  expect_terminal "JSON.TYPE" (J.type_of client ~key);
  expect_terminal "JSON.OBJLEN" (J.obj_len client ~key);
  expect_terminal "JSON.OBJKEYS" (J.obj_keys client ~key);
  expect_terminal "JSON.RESP" (J.resp client ~key)

let test_decode_get_and_mget () =
  (match J.For_testing.decode_get (R.Bulk_string "[{\"name\":\"ada\"}]") with
   | Ok (Some s) ->
       Alcotest.(check string) "get payload" "[{\"name\":\"ada\"}]" s
   | Ok None -> Alcotest.fail "expected payload"
   | Error e -> Alcotest.failf "decode get: %a" E.pp e);
  (match
     J.For_testing.decode_mget
       (R.Array
          [ R.Bulk_string "[\"ada\"]"; R.Null; R.Bulk_string "[\"grace\"]" ])
   with
   | Ok [ Some "[\"ada\"]"; None; Some "[\"grace\"]" ] -> ()
   | Ok _ -> Alcotest.fail "unexpected mget decode"
   | Error e -> Alcotest.failf "decode mget: %a" E.pp e)

let test_decode_string_shapes () =
  (match J.For_testing.decode_get R.Null with
   | Ok None -> ()
   | Ok (Some _) -> Alcotest.fail "expected null JSON.GET"
   | Error e -> Alcotest.failf "decode null get: %a" E.pp e);
  (match J.For_testing.decode_get (R.Simple_string "{}") with
   | Ok (Some "{}") -> ()
   | Ok _ -> Alcotest.fail "unexpected simple string decode"
   | Error e -> Alcotest.failf "decode simple get: %a" E.pp e);
  (match
     J.For_testing.decode_get
       (R.Verbatim_string { encoding = "txt"; data = "{\"v\":1}" })
   with
   | Ok (Some "{\"v\":1}") -> ()
   | Ok _ -> Alcotest.fail "unexpected verbatim decode"
   | Error e -> Alcotest.failf "decode verbatim get: %a" E.pp e);
  expect_protocol_violation "JSON.GET bad string"
    (J.For_testing.decode_get (R.Integer 1L))

let test_decode_type_and_lengths () =
  (match
     J.For_testing.decode_type
       (R.Array [ R.Bulk_string "object"; R.Bulk_string "array" ])
   with
   | Ok [ Some "object"; Some "array" ] -> ()
   | Ok _ -> Alcotest.fail "unexpected type decode"
   | Error e -> Alcotest.failf "decode type: %a" E.pp e);
  (match
     J.For_testing.decode_int_results "JSON.ARRLEN"
       (R.Array [ R.Integer 2L; R.Null ])
   with
   | Ok [ Some 2; None ] -> ()
   | Ok _ -> Alcotest.fail "unexpected length decode"
   | Error e -> Alcotest.failf "decode length: %a" E.pp e)

let test_decode_bool_results () =
  match
    J.For_testing.decode_bool_results "JSON.TOGGLE"
      (R.Array [ R.Integer 0L; R.Integer 1L; R.Boolean true; R.Null ])
  with
  | Ok [ Some false; Some true; Some true; None ] -> ()
  | Ok _ -> Alcotest.fail "unexpected bool decode"
  | Error e -> Alcotest.failf "decode bool: %a" E.pp e

let test_decode_bool_protocol_violation () =
  expect_protocol_violation "JSON.TOGGLE bad integer"
    (J.For_testing.decode_bool_results "JSON.TOGGLE"
       (R.Array [ R.Integer 2L ]));
  expect_protocol_violation "JSON.TOGGLE bad bulk"
    (J.For_testing.decode_bool_results "JSON.TOGGLE"
       (R.Array [ R.Bulk_string "true" ]))

let test_decode_obj_keys () =
  let reply =
    R.Array
      [ R.Array [ R.Bulk_string "name"; R.Bulk_string "age" ];
        R.Array [];
      ]
  in
  match J.For_testing.decode_obj_keys reply with
  | Ok [ Some [ "name"; "age" ]; Some [] ] -> ()
  | Ok _ -> Alcotest.fail "unexpected obj keys decode"
  | Error e -> Alcotest.failf "decode obj keys: %a" E.pp e

let test_decode_obj_key_shapes () =
  (match J.For_testing.decode_obj_keys (R.Array []) with
   | Ok [] -> ()
   | Ok _ -> Alcotest.fail "empty enhanced obj keys should be zero matches"
   | Error e -> Alcotest.failf "decode empty obj keys: %a" E.pp e);
  (match
     J.For_testing.decode_obj_keys
       (R.Array [ R.Bulk_string "name"; R.Simple_string "age" ])
   with
   | Ok [ Some [ "name"; "age" ] ] -> ()
   | Ok _ -> Alcotest.fail "unexpected restricted obj keys"
   | Error e -> Alcotest.failf "decode restricted obj keys: %a" E.pp e);
  (match J.For_testing.decode_obj_keys R.Null with
   | Ok [ None ] -> ()
   | Ok _ -> Alcotest.fail "unexpected null obj keys"
   | Error e -> Alcotest.failf "decode null obj keys: %a" E.pp e);
  (match
     J.For_testing.decode_obj_keys
       (R.Array [ R.Null; R.Array [ R.Bulk_string "nested" ] ])
   with
   | Ok [ None; Some [ "nested" ] ] -> ()
   | Ok _ -> Alcotest.fail "unexpected enhanced obj keys"
   | Error e -> Alcotest.failf "decode enhanced obj keys: %a" E.pp e);
  expect_protocol_violation "JSON.OBJKEYS bad key"
    (J.For_testing.decode_obj_keys
       (R.Array [ R.Array [ R.Integer 1L ] ]));
  expect_protocol_violation "JSON.OBJKEYS bad enhanced item"
    (J.For_testing.decode_obj_keys
       (R.Array [ R.Array [ R.Bulk_string "ok" ]; R.Bulk_string "bad" ]));
  expect_protocol_violation "JSON.OBJKEYS bad top-level"
    (J.For_testing.decode_obj_keys (R.Integer 1L))

let test_decode_protocol_violation () =
  expect_protocol_violation "JSON.MGET bad top-level"
    (J.For_testing.decode_mget (R.Integer 1L));
  expect_protocol_violation "JSON.MGET bad item"
    (J.For_testing.decode_mget (R.Array [ R.Integer 1L ]));
  expect_protocol_violation "JSON.ARRLEN bad item"
    (J.For_testing.decode_int_results "JSON.ARRLEN"
       (R.Array [ R.Bulk_string "bad" ]))

let test_decode_rejects_integer_overflow () =
  (match
     J.For_testing.decode_int_results "JSON.ARRLEN"
       (R.Array [ R.Integer Int64.max_int ])
   with
   | Error (E.Protocol_violation _) -> ()
   | Ok _ -> Alcotest.fail "expected JSON.ARRLEN overflow rejection"
   | Error e -> Alcotest.failf "expected protocol violation, got %a" E.pp e);
  let client, _seen = fake_client ~reply:(R.Integer Int64.max_int) () in
  match J.del client ~key:"json:1" with
  | Error (E.Protocol_violation _) -> ()
  | Ok _ -> Alcotest.fail "expected JSON.DEL overflow rejection"
  | Error e -> Alcotest.failf "expected protocol violation, got %a" E.pp e

let test_client_read_routing_preserves_config () =
  let seen = ref None in
  let exec ?timeout:_ target rf args =
    seen := Some (target, rf, Array.to_list args);
    Ok (R.Bulk_string "{\"name\":\"ada\"}")
  in
  let exec_multi ?timeout:_ _fan _args = [] in
  let pair ?timeout:_ _target _args1 _args2 =
    Error (E.Terminal "unused")
  in
  let router =
    Router.make ~exec ~exec_multi ~pair ~close:(fun () -> ())
      ~primary:(fun () -> None)
      ~connection_for_slot:(fun _ -> None)
      ~endpoint_for_slot:(fun _ -> None)
      ~endpoint_for_node:(fun ~node_id:_ -> None)
      ~all_connections:(fun () -> [])
      ~is_standalone:false
      ~atomic_lock_for_slot:(fun _ -> Eio.Mutex.create ())
  in
  let config = { C.Config.default with read_from = RF.Prefer_replica } in
  let client = C.from_router ~config router in
  (match J.get client ~key:"json:{1}" with
   | Ok (Some "{\"name\":\"ada\"}") -> ()
   | Ok _ -> Alcotest.fail "unexpected JSON.GET payload"
   | Error e -> Alcotest.failf "JSON.GET: %a" E.pp e);
  match !seen with
  | Some (T.By_slot s, RF.Prefer_replica, [ "JSON.GET"; "json:{1}" ])
    when s = Valkey.Slot.of_key "json:{1}" -> ()
  | Some _ ->
      Alcotest.fail "JSON.GET should preserve client read_from config"
  | None -> Alcotest.fail "fake router was not called"

let test_client_write_routing_forces_primary () =
  let seen = ref None in
  let exec ?timeout:_ target rf args =
    seen := Some (target, rf, Array.to_list args);
    Ok (R.Simple_string "OK")
  in
  let exec_multi ?timeout:_ _fan _args = [] in
  let pair ?timeout:_ _target _args1 _args2 =
    Error (E.Terminal "unused")
  in
  let router =
    Router.make ~exec ~exec_multi ~pair ~close:(fun () -> ())
      ~primary:(fun () -> None)
      ~connection_for_slot:(fun _ -> None)
      ~endpoint_for_slot:(fun _ -> None)
      ~endpoint_for_node:(fun ~node_id:_ -> None)
      ~all_connections:(fun () -> [])
      ~is_standalone:false
      ~atomic_lock_for_slot:(fun _ -> Eio.Mutex.create ())
  in
  let config = { C.Config.default with read_from = RF.Prefer_replica } in
  let client = C.from_router ~config router in
  (match J.set client ~key:"json:{1}" "{\"name\":\"ada\"}" with
   | Ok true -> ()
   | Ok false -> Alcotest.fail "JSON.SET unexpectedly returned null"
   | Error e -> Alcotest.failf "JSON.SET: %a" E.pp e);
  match !seen with
  | Some
      ( T.By_slot s,
        RF.Primary,
        [ "JSON.SET"; "json:{1}"; "$"; "{\"name\":\"ada\"}" ] )
    when s = Valkey.Slot.of_key "json:{1}" -> ()
  | Some _ -> Alcotest.fail "JSON.SET should force Primary"
  | None -> Alcotest.fail "fake router was not called"

let tests =
  [ Alcotest.test_case "JSON.SET args" `Quick test_set_args;
    Alcotest.test_case "JSON.GET args with formatting" `Quick
      test_get_args_with_format;
    Alcotest.test_case "JSON.MGET args" `Quick test_mget_args;
    Alcotest.test_case "JSON.ARRAPPEND args" `Quick test_arr_append_args;
    Alcotest.test_case "JSON.SET conditions and replies" `Quick
      test_set_conditions_and_reply_shapes;
    Alcotest.test_case "JSON.MSET args and empty input" `Quick
      test_mset_args_and_empty_input;
    Alcotest.test_case "JSON key/path and number commands" `Quick
      test_key_path_and_number_commands;
    Alcotest.test_case "JSON protocol violations and errors" `Quick
      test_protocol_violations_and_errors;
    Alcotest.test_case "JSON array commands" `Quick test_array_commands;
    Alcotest.test_case "JSON array argument variants" `Quick
      test_array_argument_variants;
    Alcotest.test_case "JSON string/object/RESP commands" `Quick
      test_string_object_and_resp_commands;
    Alcotest.test_case "JSON read overrides and scalar decodes" `Quick
      test_read_overrides_and_scalar_decodes;
    Alcotest.test_case "JSON reply variants" `Quick test_reply_variants;
    Alcotest.test_case "JSON transport errors" `Quick
      test_transport_errors;
    Alcotest.test_case "decode JSON.GET and JSON.MGET" `Quick
      test_decode_get_and_mget;
    Alcotest.test_case "decode JSON string shapes" `Quick
      test_decode_string_shapes;
    Alcotest.test_case "decode JSON.TYPE and length results" `Quick
      test_decode_type_and_lengths;
    Alcotest.test_case "decode JSON.TOGGLE results" `Quick
      test_decode_bool_results;
    Alcotest.test_case "decode JSON.TOGGLE rejects bad bool" `Quick
      test_decode_bool_protocol_violation;
    Alcotest.test_case "decode JSON.OBJKEYS" `Quick test_decode_obj_keys;
    Alcotest.test_case "decode JSON.OBJKEYS shapes" `Quick
      test_decode_obj_key_shapes;
    Alcotest.test_case "decode rejects bad MGET shape" `Quick
      test_decode_protocol_violation;
    Alcotest.test_case "decode rejects integer overflow" `Quick
      test_decode_rejects_integer_overflow;
    Alcotest.test_case "JSON.GET preserves read routing" `Quick
      test_client_read_routing_preserves_config;
    Alcotest.test_case "JSON.SET forces primary routing" `Quick
      test_client_write_routing_forces_primary;
  ]
