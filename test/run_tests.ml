let () =
  Alcotest.run "valkey"
    [ "resp3", Test_resp3.tests;
      "valkey_error", Test_valkey_error.tests;
      "connection (needs docker valkey :6379)", Test_connection.tests;
    ]
