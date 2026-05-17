module C = Valkey.Client
module B = Valkey.Bloom
module E = Valkey.Connection.Error

let host = "localhost"

let port () =
  match Sys.getenv_opt "VALKEY_BLOOM_PORT" with
  | Some s ->
      (match int_of_string_opt s with
       | Some p -> p
       | None -> 6381)
  | None -> 6381

let err_pp = E.pp

let with_client f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let c =
    C.connect ~sw
      ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~host ~port:(port ()) ()
  in
  Fun.protect ~finally:(fun () -> C.close c) @@ fun () -> f c

let bloom_available () =
  try
    with_client @@ fun c ->
    match B.card c ~key:"ocaml:bloom:missing" with
    | Ok _ -> true
    | Error _ -> false
  with _ -> false

let skipped name () =
  Printf.printf
    "[skipped] %s (need valkey-bundle on localhost:%d; \
     docker compose -f docker-compose.search.yml up -d, or set \
     VALKEY_BLOOM_PORT to override)\n%!"
    name (port ())

let expect_ok ctx = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s: %a" ctx err_pp e

let delete c key = ignore (C.del c [ key ])

let test_bloom_filter_workflow () =
  with_client @@ fun c ->
  let key = "ocaml:bloom:users" in
  let inserted_key = "ocaml:bloom:inserted" in
  let nonscaling_key = "ocaml:bloom:nonscaling" in
  delete c key;
  delete c inserted_key;
  delete c nonscaling_key;

  expect_ok "BF.RESERVE"
    (B.reserve c ~key ~error_rate:0.01 ~capacity:1000);
  Alcotest.(check bool) "first add" true
    (expect_ok "BF.ADD" (B.add c ~key "ada"));
  Alcotest.(check bool) "duplicate add" false
    (expect_ok "BF.ADD duplicate" (B.add c ~key "ada"));
  Alcotest.(check (list bool)) "madd mixed"
    [ true; false; true ]
    (expect_ok "BF.MADD" (B.madd c ~key [ "grace"; "ada"; "katherine" ]));
  Alcotest.(check bool) "exists present" true
    (expect_ok "BF.EXISTS present" (B.exists c ~key "ada"));
  Alcotest.(check bool) "exists absent" false
    (expect_ok "BF.EXISTS absent" (B.exists c ~key "missing"));
  Alcotest.(check (list bool)) "mexists mixed"
    [ true; false; true ]
    (expect_ok "BF.MEXISTS"
       (B.mexists c ~key [ "ada"; "missing"; "grace" ]));
  Alcotest.(check int) "card" 3
    (expect_ok "BF.CARD" (B.card c ~key));

  let info = expect_ok "BF.INFO" (B.info c ~key) in
  Alcotest.(check int) "info capacity" 1000 info.capacity;
  Alcotest.(check int) "info filters" 1 info.filters;
  Alcotest.(check bool) "info has raw payload" true
    (List.mem_assoc "Capacity" info.raw);
  (match expect_ok "BF.INFO ERROR" (B.info_value c ~key B.Error_rate) with
   | B.Float f -> Alcotest.(check (float 0.000001)) "error rate" 0.01 f
   | _ -> Alcotest.fail "unexpected BF.INFO ERROR shape");

  let insert_options : B.insert_options =
    { B.default_insert_options with
      capacity = Some 200;
      error_rate = Some 0.001;
      scaling = B.Expansion 2;
    }
  in
  Alcotest.(check (list bool)) "insert creates and adds"
    [ true; true; false ]
    (expect_ok "BF.INSERT"
       (B.insert c ~options:insert_options ~key:inserted_key
          ~items:[ "red"; "blue"; "red" ]));
  Alcotest.(check bool) "inserted exists" true
    (expect_ok "BF.EXISTS inserted"
       (B.exists c ~key:inserted_key "blue"));

  expect_ok "BF.RESERVE non-scaling"
    (B.reserve c ~scaling:B.Non_scaling ~key:nonscaling_key
       ~error_rate:0.01 ~capacity:5);
  (match
     expect_ok "BF.INFO EXPANSION"
       (B.info_value c ~key:nonscaling_key B.Expansion_rate)
   with
   | B.Not_applicable -> ()
   | _ -> Alcotest.fail "non-scaling expansion should be nil");

  delete c key;
  delete c inserted_key;
  delete c nonscaling_key

let tests =
  let available = bloom_available () in
  let tc name f =
    if available then Alcotest.test_case name `Quick f
    else Alcotest.test_case name `Quick (skipped name)
  in
  [ tc "Bloom filter workflow" test_bloom_filter_workflow ]
