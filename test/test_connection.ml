module C = Valkey.Connection
module R = Valkey.Resp3

let host = "localhost"
let port = 6379

let with_connection f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let conn = C.connect ~sw ~net ~clock ~host ~port () in
  let result = f env sw conn in
  C.close conn;
  result

let expect_bulk_eq ~ctx ~expected got =
  match got with
  | Ok (R.Bulk_string s) when s = expected -> ()
  | Ok other ->
      Alcotest.failf "%s: expected bulk %S, got %a" ctx expected R.pp other
  | Error e ->
      Alcotest.failf "%s: expected bulk %S, got error %a" ctx expected
        C.Error.pp e

let expect_simple_eq ~ctx ~expected got =
  match got with
  | Ok (R.Simple_string s) when s = expected -> ()
  | Ok other ->
      Alcotest.failf "%s: expected +%s, got %a" ctx expected R.pp other
  | Error e ->
      Alcotest.failf "%s: expected +%s, got error %a" ctx expected
        C.Error.pp e

let test_ping () =
  with_connection @@ fun _env _sw conn ->
  expect_simple_eq ~ctx:"PING" ~expected:"PONG"
    (C.request conn [| "PING" |]);
  expect_bulk_eq ~ctx:"PING msg" ~expected:"hi"
    (C.request conn [| "PING"; "hi" |])

let test_set_and_get () =
  with_connection @@ fun _env _sw conn ->
  expect_simple_eq ~ctx:"SET" ~expected:"OK"
    (C.request conn [| "SET"; "ocaml:test:k"; "v1" |]);
  expect_bulk_eq ~ctx:"GET" ~expected:"v1"
    (C.request conn [| "GET"; "ocaml:test:k" |]);
  ignore (C.request conn [| "DEL"; "ocaml:test:k" |])

let test_wrong_type_error () =
  with_connection @@ fun _env _sw conn ->
  ignore (C.request conn [| "DEL"; "ocaml:test:wt" |]);
  ignore (C.request conn [| "SET"; "ocaml:test:wt"; "scalar" |]);
  (match C.request conn [| "LPUSH"; "ocaml:test:wt"; "x" |] with
   | Error (C.Error.Server_error ve) when ve.code = "WRONGTYPE" -> ()
   | Error e ->
       Alcotest.failf "expected WRONGTYPE, got error %a" C.Error.pp e
   | Ok v -> Alcotest.failf "expected error, got %a" R.pp v);
  ignore (C.request conn [| "DEL"; "ocaml:test:wt" |])

let test_concurrent_set_get () =
  with_connection @@ fun _env _sw conn ->
  let n = 50 in
  let keys = List.init n (fun i -> Printf.sprintf "ocaml:test:c:%d" i) in
  ignore (C.request conn (Array.of_list ("DEL" :: keys)));
  Eio.Fiber.all
    (List.mapi
       (fun i k () ->
         let v = Printf.sprintf "val-%d" i in
         match C.request conn [| "SET"; k; v |] with
         | Ok _ -> ()
         | Error e ->
             Alcotest.failf "SET %s failed: %a" k C.Error.pp e)
       keys);
  Eio.Fiber.all
    (List.mapi
       (fun i k () ->
         let expected = Printf.sprintf "val-%d" i in
         expect_bulk_eq ~ctx:(Printf.sprintf "GET %s" k)
           ~expected (C.request conn [| "GET"; k |]))
       keys);
  ignore (C.request conn (Array.of_list ("DEL" :: keys)))

let test_large_value () =
  with_connection @@ fun _env _sw conn ->
  let key = "ocaml:test:large" in
  let size = 16 * 1024 in
  let value = String.make size 'x' in
  ignore (C.request conn [| "DEL"; key |]);
  expect_simple_eq ~ctx:"SET large" ~expected:"OK"
    (C.request conn [| "SET"; key; value |]);
  expect_bulk_eq ~ctx:"GET large" ~expected:value
    (C.request conn [| "GET"; key |]);
  ignore (C.request conn [| "DEL"; key |])

let test_availability_zone () =
  with_connection @@ fun _env _sw conn ->
  (* Plain Docker Valkey has no AZ configured, so expect None. Just a liveness
     probe that the field is accessible. *)
  let _ = C.availability_zone conn in
  ()

let tests =
  [ Alcotest.test_case "ping" `Quick test_ping;
    Alcotest.test_case "set and get" `Quick test_set_and_get;
    Alcotest.test_case "wrong type error" `Quick test_wrong_type_error;
    Alcotest.test_case "concurrent set/get 50 fibers" `Slow
      test_concurrent_set_get;
    Alcotest.test_case "16 KiB value round-trip" `Slow test_large_value;
    Alcotest.test_case "availability_zone accessor" `Quick
      test_availability_zone;
  ]
