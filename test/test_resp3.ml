module R = Valkey.Resp3
module P = Valkey.Resp3_parser
module W = Valkey.Resp3_writer

let resp3 = Alcotest.testable R.pp R.equal

let parse s = P.read (P.of_buf_read (Eio.Buf_read.of_string s))

let test_simple_string () =
  Alcotest.check resp3 "PONG" (R.Simple_string "PONG") (parse "+PONG\r\n")

let test_simple_error () =
  Alcotest.check resp3 "wrongtype" (R.Simple_error "WRONGTYPE foo")
    (parse "-WRONGTYPE foo\r\n")

let test_integer () =
  Alcotest.check resp3 "42" (R.Integer 42L) (parse ":42\r\n");
  Alcotest.check resp3 "neg" (R.Integer (-1L)) (parse ":-1\r\n");
  Alcotest.check resp3 "i64" (R.Integer 9223372036854775807L)
    (parse ":9223372036854775807\r\n")

let test_bulk_string () =
  Alcotest.check resp3 "hello" (R.Bulk_string "hello")
    (parse "$5\r\nhello\r\n");
  Alcotest.check resp3 "empty" (R.Bulk_string "") (parse "$0\r\n\r\n");
  Alcotest.check resp3 "binary with CRLF"
    (R.Bulk_string "a\r\nb") (parse "$4\r\na\r\nb\r\n")

let test_null () =
  Alcotest.check resp3 "resp3 null" R.Null (parse "_\r\n");
  Alcotest.check resp3 "resp2 null bulk" R.Null (parse "$-1\r\n");
  Alcotest.check resp3 "resp2 null array" R.Null (parse "*-1\r\n")

let test_boolean () =
  Alcotest.check resp3 "true" (R.Boolean true) (parse "#t\r\n");
  Alcotest.check resp3 "false" (R.Boolean false) (parse "#f\r\n")

let test_double () =
  Alcotest.check resp3 "1.5" (R.Double 1.5) (parse ",1.5\r\n");
  Alcotest.check resp3 "inf" (R.Double Float.infinity) (parse ",inf\r\n");
  Alcotest.check resp3 "-inf" (R.Double Float.neg_infinity) (parse ",-inf\r\n")

let test_array () =
  Alcotest.check resp3 "three"
    (R.Array [ R.Integer 1L; R.Integer 2L; R.Integer 3L ])
    (parse "*3\r\n:1\r\n:2\r\n:3\r\n");
  Alcotest.check resp3 "empty" (R.Array []) (parse "*0\r\n")

let test_map () =
  Alcotest.check resp3 "hello map"
    (R.Map
       [ R.Bulk_string "proto", R.Integer 3L;
         R.Bulk_string "id", R.Integer 42L ])
    (parse "%2\r\n$5\r\nproto\r\n:3\r\n$2\r\nid\r\n:42\r\n")

let test_set () =
  Alcotest.check resp3 "set"
    (R.Set [ R.Bulk_string "a"; R.Bulk_string "b" ])
    (parse "~2\r\n$1\r\na\r\n$1\r\nb\r\n")

let test_push () =
  Alcotest.check resp3 "push"
    (R.Push [ R.Bulk_string "invalidate"; R.Array [ R.Bulk_string "k" ] ])
    (parse ">2\r\n$10\r\ninvalidate\r\n*1\r\n$1\r\nk\r\n")

let test_verbatim_string () =
  Alcotest.check resp3 "txt"
    (R.Verbatim_string { encoding = "txt"; data = "hello" })
    (parse "=9\r\ntxt:hello\r\n")

let test_bulk_error () =
  Alcotest.check resp3 "bulk err"
    (R.Bulk_error "CODE long message")
    (parse "!17\r\nCODE long message\r\n")

let test_big_number () =
  Alcotest.check resp3 "big"
    (R.Big_number "3492890328409238509324850943850943825024385")
    (parse "(3492890328409238509324850943850943825024385\r\n")

let test_nested () =
  Alcotest.check resp3 "array of arrays"
    (R.Array [ R.Array [ R.Integer 1L ]; R.Array [ R.Integer 2L ] ])
    (parse "*2\r\n*1\r\n:1\r\n*1\r\n:2\r\n")

let test_attribute_skip () =
  Alcotest.check resp3 "attribute is skipped"
    (R.Integer 42L)
    (parse "|1\r\n+key\r\n+val\r\n:42\r\n")

let test_streamed_raises () =
  Alcotest.check_raises "streamed bulk"
    (P.Parse_error "streamed bulk strings not yet implemented")
    (fun () -> ignore (parse "$?\r\n;4\r\ntest\r\n;0\r\n"))

let test_writer_command () =
  let got = W.command_to_string [| "PING" |] in
  Alcotest.(check string) "PING" "*1\r\n$4\r\nPING\r\n" got;
  let got2 = W.command_to_string [| "SET"; "k"; "v" |] in
  Alcotest.(check string) "SET" "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n" got2;
  let got3 = W.command_to_string [| "SET"; "k"; "a\r\nb" |] in
  Alcotest.(check string) "SET with CRLF"
    "*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$4\r\na\r\nb\r\n" got3

let tests =
  [ Alcotest.test_case "simple string" `Quick test_simple_string;
    Alcotest.test_case "simple error" `Quick test_simple_error;
    Alcotest.test_case "integer" `Quick test_integer;
    Alcotest.test_case "bulk string" `Quick test_bulk_string;
    Alcotest.test_case "null" `Quick test_null;
    Alcotest.test_case "boolean" `Quick test_boolean;
    Alcotest.test_case "double" `Quick test_double;
    Alcotest.test_case "array" `Quick test_array;
    Alcotest.test_case "map" `Quick test_map;
    Alcotest.test_case "set" `Quick test_set;
    Alcotest.test_case "push" `Quick test_push;
    Alcotest.test_case "verbatim string" `Quick test_verbatim_string;
    Alcotest.test_case "bulk error" `Quick test_bulk_error;
    Alcotest.test_case "big number" `Quick test_big_number;
    Alcotest.test_case "nested array" `Quick test_nested;
    Alcotest.test_case "attribute is skipped" `Quick test_attribute_skip;
    Alcotest.test_case "streamed raises" `Quick test_streamed_raises;
    Alcotest.test_case "writer commands" `Quick test_writer_command;
  ]
