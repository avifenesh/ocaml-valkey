module E = Valkey.Error

let verror = Alcotest.testable E.pp E.equal

let test_code_and_message () =
  Alcotest.check verror "typed split"
    { code = "WRONGTYPE"; message = "Operation against a key holding the wrong kind of value" }
    (E.of_string "WRONGTYPE Operation against a key holding the wrong kind of value")

let test_bare_code () =
  Alcotest.check verror "bare code"
    { code = "ERR"; message = "" }
    (E.of_string "ERR")

let test_empty () =
  Alcotest.check verror "empty"
    { code = ""; message = "" }
    (E.of_string "")

let test_roundtrip () =
  let e = E.of_string "NOAUTH Authentication required." in
  Alcotest.(check string) "to_string"
    "NOAUTH Authentication required." (E.to_string e)

let tests =
  [ Alcotest.test_case "code and message" `Quick test_code_and_message;
    Alcotest.test_case "bare code" `Quick test_bare_code;
    Alcotest.test_case "empty" `Quick test_empty;
    Alcotest.test_case "to_string roundtrip" `Quick test_roundtrip;
  ]
