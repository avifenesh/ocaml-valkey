module R = Valkey.Redirect
module VE = Valkey.Error

let ve code message : VE.t = { code; message }

let test_moved () =
  match R.of_valkey_error (ve "MOVED" "12182 10.0.0.1:6379") with
  | Some { kind = R.Moved; slot = 12182; host = "10.0.0.1"; port = 6379 } -> ()
  | _ -> Alcotest.fail "expected MOVED parse"

let test_ask () =
  match R.of_valkey_error (ve "ASK" "5461 10.0.0.2:6380") with
  | Some { kind = R.Ask; slot = 5461; host = "10.0.0.2"; port = 6380 } -> ()
  | _ -> Alcotest.fail "expected ASK parse"

let test_ipv6_host () =
  match R.of_valkey_error (ve "MOVED" "1 ::1:6379") with
  | Some { host; port = 6379; _ } ->
      Alcotest.(check string) "ipv6 host" "::1" host
  | _ -> Alcotest.fail "expected parse"

let test_non_redirect_error () =
  match R.of_valkey_error (ve "WRONGTYPE" "Operation against a key ...") with
  | None -> ()
  | Some _ -> Alcotest.fail "WRONGTYPE should not be a redirect"

let test_malformed_message () =
  List.iter
    (fun msg ->
      match R.of_valkey_error (ve "MOVED" msg) with
      | None -> ()
      | Some _ ->
          Alcotest.failf "expected None for malformed %S" msg)
    [ ""; "12182"; "12182 host-no-port";
      "notanumber host:6379"; "12182 host:notanumber" ]

let tests =
  [ Alcotest.test_case "MOVED parse" `Quick test_moved;
    Alcotest.test_case "ASK parse" `Quick test_ask;
    Alcotest.test_case "IPv6 host (last-colon split)" `Quick test_ipv6_host;
    Alcotest.test_case "non-redirect errors ignored" `Quick
      test_non_redirect_error;
    Alcotest.test_case "malformed messages return None" `Quick
      test_malformed_message;
  ]
