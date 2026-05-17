module B = Valkey.Bloom
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
  | Error e ->
      Alcotest.failf "%s: expected protocol violation, got %a" name E.pp e

let expect_terminal name = function
  | Error (E.Terminal "wire closed") -> ()
  | Ok _ -> Alcotest.fail (name ^ " should pass through transport errors")
  | Error e -> Alcotest.failf "%s: unexpected transport error %a" name E.pp e

let test_reserve_args () =
  array_check "BF.RESERVE default"
    [| "BF.RESERVE"; "bf:users"; "0.01"; "1000" |]
    (B.For_testing.reserve_args
       ~scaling:B.Default_scaling ~key:"bf:users"
       ~error_rate:0.01 ~capacity:1000);
  array_check "BF.RESERVE expansion"
    [| "BF.RESERVE"; "bf:users"; "0.001"; "1000"; "EXPANSION"; "4" |]
    (B.For_testing.reserve_args
       ~scaling:(B.Expansion 4) ~key:"bf:users"
       ~error_rate:0.001 ~capacity:1000);
  array_check "BF.RESERVE non-scaling"
    [| "BF.RESERVE"; "bf:users"; "0.01"; "1000"; "NONSCALING" |]
    (B.For_testing.reserve_args
       ~scaling:B.Non_scaling ~key:"bf:users"
       ~error_rate:0.01 ~capacity:1000)

let test_insert_args () =
  let options : B.insert_options =
    { capacity = Some 1000;
      error_rate = Some 0.001;
      scaling = B.Expansion 4;
      seed = Some "01234567890123456789012345678901";
      tightening = Some 0.5;
      validate_scale_to = Some 5000;
      no_create = true;
    }
  in
  array_check "BF.INSERT full"
    [| "BF.INSERT"; "bf:users";
       "CAPACITY"; "1000";
       "ERROR"; "0.001";
       "EXPANSION"; "4";
       "SEED"; "01234567890123456789012345678901";
       "TIGHTENING"; "0.5";
       "VALIDATESCALETO"; "5000";
       "NOCREATE";
       "ITEMS"; "ada"; "grace";
    |]
    (B.For_testing.insert_args ~options ~key:"bf:users"
       ~items:[ "ada"; "grace" ]);
  let options =
    { B.default_insert_options with scaling = B.Non_scaling }
  in
  array_check "BF.INSERT non-scaling no items"
    [| "BF.INSERT"; "bf:users"; "NONSCALING" |]
    (B.For_testing.insert_args ~options ~key:"bf:users" ~items:[]);
  let options =
    { B.default_insert_options with
      scaling = B.Non_scaling;
      validate_scale_to = Some 1000;
    }
  in
  expect_invalid_arg "BF.INSERT mutually exclusive options" (fun () ->
    ignore
      (B.For_testing.insert_args ~options ~key:"bf:users"
         ~items:[ "ada" ]))

let test_info_args () =
  array_check "BF.INFO full"
    [| "BF.INFO"; "bf:users" |]
    (B.For_testing.info_args ~key:"bf:users" ());
  array_check "BF.INFO selector"
    [| "BF.INFO"; "bf:users"; "MAXSCALEDCAPACITY" |]
    (B.For_testing.info_args ~selector:B.Max_scaled_capacity
       ~key:"bf:users" ())

let test_wrappers_route_and_decode () =
  let key = "bf:{users}" in
  let client, seen = fake_client ~reply:(R.Simple_string "OK") () in
  (match B.reserve client ~key ~error_rate:0.01 ~capacity:1000 with
   | Ok () -> ()
   | Error e -> Alcotest.failf "BF.RESERVE: %a" E.pp e);
  check_seen "BF.RESERVE" ~key ~read_from:RF.Primary
    ~args:[ "BF.RESERVE"; key; "0.01"; "1000" ] seen;

  let client, seen = fake_client ~reply:(R.Integer 1L) () in
  Alcotest.(check bool) "BF.ADD true" true
    (match B.add client ~key "ada" with
     | Ok v -> v
     | Error e -> Alcotest.failf "BF.ADD: %a" E.pp e);
  check_seen "BF.ADD" ~key ~read_from:RF.Primary
    ~args:[ "BF.ADD"; key; "ada" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 1L; R.Integer 0L ]) ()
  in
  Alcotest.(check (list bool)) "BF.MADD"
    [ true; false ]
    (match B.madd client ~key [ "ada"; "ada" ] with
     | Ok v -> v
     | Error e -> Alcotest.failf "BF.MADD: %a" E.pp e);
  check_seen "BF.MADD" ~key ~read_from:RF.Primary
    ~args:[ "BF.MADD"; key; "ada"; "ada" ] seen;

  let client, seen = fake_client ~reply:(R.Integer 0L) () in
  Alcotest.(check bool) "BF.EXISTS false" false
    (match B.exists client ~read_from:RF.Prefer_replica ~key "grace" with
     | Ok v -> v
     | Error e -> Alcotest.failf "BF.EXISTS: %a" E.pp e);
  check_seen "BF.EXISTS" ~key ~read_from:RF.Prefer_replica
    ~args:[ "BF.EXISTS"; key; "grace" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 1L; R.Integer 0L ])
      ~read_from:RF.Prefer_replica ()
  in
  Alcotest.(check (list bool)) "BF.MEXISTS"
    [ true; false ]
    (match B.mexists client ~key [ "ada"; "grace" ] with
     | Ok v -> v
     | Error e -> Alcotest.failf "BF.MEXISTS: %a" E.pp e);
  check_seen "BF.MEXISTS" ~key ~read_from:RF.Prefer_replica
    ~args:[ "BF.MEXISTS"; key; "ada"; "grace" ] seen;

  let client, seen =
    fake_client ~reply:(R.Array [ R.Integer 1L; R.Integer 1L ]) ()
  in
  Alcotest.(check (list bool)) "BF.INSERT"
    [ true; true ]
    (match B.insert client ~key ~items:[ "x"; "y" ] with
     | Ok v -> v
     | Error e -> Alcotest.failf "BF.INSERT: %a" E.pp e);
  check_seen "BF.INSERT" ~key ~read_from:RF.Primary
    ~args:[ "BF.INSERT"; key; "ITEMS"; "x"; "y" ] seen;

  let client, seen = fake_client ~reply:(R.Integer 42L) () in
  Alcotest.(check int) "BF.CARD" 42
    (match B.card client ~read_from:RF.Prefer_replica ~key with
     | Ok v -> v
     | Error e -> Alcotest.failf "BF.CARD: %a" E.pp e);
  check_seen "BF.CARD" ~key ~read_from:RF.Prefer_replica
    ~args:[ "BF.CARD"; key ] seen;

  let client, seen = fake_client ~reply:(R.Simple_string "OK") () in
  (match B.load client ~key ~dump:"opaque" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "BF.LOAD: %a" E.pp e);
  check_seen "BF.LOAD" ~key ~read_from:RF.Primary
    ~args:[ "BF.LOAD"; key; "opaque" ] seen

let info_payload ?(expansion = R.Integer 2L) () =
  R.Array
    [ R.Bulk_string "Capacity"; R.Integer 1000L;
      R.Bulk_string "Size"; R.Integer 1463L;
      R.Bulk_string "Number of filters"; R.Integer 1L;
      R.Bulk_string "Number of items inserted"; R.Integer 12L;
      R.Bulk_string "Error rate"; R.Bulk_string "0.01";
      R.Bulk_string "Expansion rate"; expansion;
      R.Bulk_string "Tightening ratio"; R.Bulk_string "0.5";
      R.Bulk_string "Max scaled capacity"; R.Integer 32767000L;
    ]

let test_info_decoders () =
  (match B.For_testing.decode_info_raw (info_payload ()) with
   | Ok pairs ->
       Alcotest.(check bool) "raw includes capacity" true
         (List.mem_assoc "Capacity" pairs)
   | Error e -> Alcotest.failf "BF.INFO raw: %a" E.pp e);
  let info =
    match B.For_testing.decode_info (info_payload ()) with
    | Ok info -> info
    | Error e -> Alcotest.failf "BF.INFO parsed: %a" E.pp e
  in
  Alcotest.(check int) "capacity" 1000 info.capacity;
  Alcotest.(check int) "size" 1463 info.size;
  Alcotest.(check int) "filters" 1 info.filters;
  Alcotest.(check int) "items" 12 info.items;
  Alcotest.(check (float 0.000001)) "error rate" 0.01 info.error_rate;
  Alcotest.(check (option int)) "expansion" (Some 2) info.expansion;
  Alcotest.(check (option (float 0.000001))) "tightening"
    (Some 0.5) info.tightening;
  Alcotest.(check (option int)) "max scale"
    (Some 32767000) info.max_scaled_capacity

let test_info_decodes_non_scaling_nulls () =
  let payload =
    R.Array
      [ R.Bulk_string "Capacity"; R.Integer 5L;
        R.Bulk_string "Size"; R.Integer 270L;
        R.Bulk_string "Number of filters"; R.Integer 1L;
        R.Bulk_string "Number of items inserted"; R.Integer 0L;
        R.Bulk_string "Error rate"; R.Bulk_string "0.01";
        R.Bulk_string "Expansion rate"; R.Null;
      ]
  in
  match B.For_testing.decode_info payload with
  | Ok info ->
      Alcotest.(check (option int)) "expansion" None info.expansion;
      Alcotest.(check (option (float 0.000001))) "tightening" None
        info.tightening;
      Alcotest.(check (option int)) "max scaled" None
        info.max_scaled_capacity
  | Error e -> Alcotest.failf "BF.INFO non-scaling: %a" E.pp e

let test_info_value_decoders () =
  (match B.For_testing.decode_info_value B.Capacity (R.Integer 100L) with
   | Ok (B.Int 100) -> ()
   | Ok _ -> Alcotest.fail "unexpected capacity selector value"
   | Error e -> Alcotest.failf "capacity selector: %a" E.pp e);
  (match B.For_testing.decode_info_value B.Error_rate (R.Bulk_string "0.01") with
   | Ok (B.Float f) ->
       Alcotest.(check (float 0.000001)) "error selector" 0.01 f
   | Ok _ -> Alcotest.fail "unexpected error selector value"
   | Error e -> Alcotest.failf "error selector: %a" E.pp e);
  (match B.For_testing.decode_info_value B.Expansion_rate R.Null with
   | Ok B.Not_applicable -> ()
   | Ok _ -> Alcotest.fail "unexpected expansion selector value"
   | Error e -> Alcotest.failf "expansion selector: %a" E.pp e)

let test_invalid_input () =
  let client, _seen = fake_client () in
  expect_invalid_arg "BF.MADD empty" (fun () ->
    ignore (B.madd client ~key:"bf" []));
  expect_invalid_arg "BF.MEXISTS empty" (fun () ->
    ignore (B.mexists client ~key:"bf" []));
  let options =
    { B.default_insert_options with
      scaling = B.Non_scaling;
      validate_scale_to = Some 10;
    }
  in
  expect_invalid_arg "BF.INSERT invalid options" (fun () ->
    ignore (B.insert client ~options ~key:"bf" ~items:[ "x" ]))

let test_protocol_violations () =
  expect_protocol_violation "BF.ADD bad bool"
    (B.For_testing.decode_bools "BF.ADD" (R.Array [ R.Integer 2L ]));
  expect_protocol_violation "BF.MADD scalar"
    (B.For_testing.decode_bools "BF.MADD" (R.Integer 1L));
  expect_protocol_violation "BF.INFO odd array"
    (B.For_testing.decode_info_raw
       (R.Array [ R.Bulk_string "Capacity" ]));
  expect_protocol_violation "BF.INFO missing field"
    (B.For_testing.decode_info
       (R.Array [ R.Bulk_string "Size"; R.Integer 1L ]));
  expect_protocol_violation "BF.INFO bad float"
    (B.For_testing.decode_info_value B.Error_rate
       (R.Bulk_string "not-a-float"));
  let client, _seen = fake_client ~reply:(R.Integer 2L) () in
  expect_protocol_violation "BF.EXISTS bad bool"
    (B.exists client ~key:"bf" "x")

let test_transport_errors () =
  let client, _seen =
    fake_client ~error:(E.Terminal "wire closed") ()
  in
  expect_terminal "BF.RESERVE"
    (B.reserve client ~key:"bf" ~error_rate:0.01 ~capacity:10);
  expect_terminal "BF.ADD" (B.add client ~key:"bf" "x");
  expect_terminal "BF.MADD" (B.madd client ~key:"bf" [ "x" ]);
  expect_terminal "BF.EXISTS" (B.exists client ~key:"bf" "x");
  expect_terminal "BF.MEXISTS" (B.mexists client ~key:"bf" [ "x" ]);
  expect_terminal "BF.INSERT"
    (B.insert client ~key:"bf" ~items:[ "x" ]);
  expect_terminal "BF.CARD" (B.card client ~key:"bf");
  expect_terminal "BF.INFO" (B.info client ~key:"bf");
  expect_terminal "BF.INFO selector"
    (B.info_value client ~key:"bf" B.Capacity);
  expect_terminal "BF.LOAD" (B.load client ~key:"bf" ~dump:"opaque")

let tests =
  [ Alcotest.test_case "BF.RESERVE args" `Quick test_reserve_args;
    Alcotest.test_case "BF.INSERT args" `Quick test_insert_args;
    Alcotest.test_case "BF.INFO args" `Quick test_info_args;
    Alcotest.test_case "Bloom wrappers route and decode" `Quick
      test_wrappers_route_and_decode;
    Alcotest.test_case "decode BF.INFO" `Quick test_info_decoders;
    Alcotest.test_case "decode non-scaling BF.INFO" `Quick
      test_info_decodes_non_scaling_nulls;
    Alcotest.test_case "decode BF.INFO selector values" `Quick
      test_info_value_decoders;
    Alcotest.test_case "Bloom rejects invalid input" `Quick
      test_invalid_input;
    Alcotest.test_case "Bloom rejects bad reply shapes" `Quick
      test_protocol_violations;
    Alcotest.test_case "Bloom transport errors" `Quick
      test_transport_errors;
  ]
