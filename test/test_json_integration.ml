module C = Valkey.Client
module J = Valkey.Json
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let host = "localhost"

let port () =
  match Sys.getenv_opt "VALKEY_JSON_PORT" with
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

let json_available () =
  try
    with_client @@ fun c ->
    match J.type_of c ~key:"ocaml:json:missing" with
    | Ok _ -> true
    | Error _ -> false
  with _ -> false

let skipped name () =
  Printf.printf
    "[skipped] %s (need valkey-bundle on localhost:%d; \
     docker compose -f docker-compose.search.yml up -d, or set \
     VALKEY_JSON_PORT to override)\n%!"
    name (port ())

let contains ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

let expect_ok ctx = function
  | Ok v -> v
  | Error e -> Alcotest.failf "%s: %a" ctx err_pp e

let expect_set ctx = function
  | Ok true -> ()
  | Ok false -> Alcotest.failf "%s: condition prevented write" ctx
  | Error e -> Alcotest.failf "%s: %a" ctx err_pp e

let check_int_options name expected actual =
  Alcotest.(check (list (option int))) name expected actual

let test_json_document_workflow () =
  with_client @@ fun c ->
  let key = "ocaml:json:doc:1" in
  let key2 = "ocaml:json:doc:2" in
  let key3 = "ocaml:json:doc:3" in
  ignore (J.del c ~key);
  ignore (J.del c ~key:key2);
  ignore (J.del c ~key:key3);
  expect_set "JSON.SET"
    (J.set c ~key
       "{\"name\":\"ada\",\"age\":36,\"tags\":[\"math\"],\
        \"active\":true,\"meta\":{\"country\":\"uk\"}}");
  (match expect_ok "JSON.GET" (J.get c ~key) with
   | Some payload ->
       Alcotest.(check bool) "payload has name" true
         (contains ~needle:"\"name\":\"ada\"" payload)
   | None -> Alcotest.fail "missing JSON.GET payload");
  Alcotest.(check (list (option string))) "root type" [ Some "object" ]
    (expect_ok "JSON.TYPE" (J.type_of c ~path:"$" ~key));
  (match expect_ok "JSON.OBJKEYS" (J.obj_keys c ~path:"$" ~key) with
   | Some keys :: _ ->
       Alcotest.(check bool) "has age key" true (List.mem "age" keys)
   | None :: _ -> Alcotest.fail "root object keys were null"
   | [] -> Alcotest.fail "missing object keys");
  Alcotest.(check (list (option int))) "object len" [ Some 5 ]
    (expect_ok "JSON.OBJLEN" (J.obj_len c ~path:"$" ~key));
  check_int_options "append length" [ Some 2 ]
    (expect_ok "JSON.ARRAPPEND"
       (J.arr_append c ~key ~path:"$.tags" [ "\"logic\"" ]));
  check_int_options "insert length" [ Some 3 ]
    (expect_ok "JSON.ARRINSERT"
       (J.arr_insert c ~key ~path:"$.tags" ~index:1 [ "\"poetry\"" ]));
  check_int_options "array length" [ Some 2 ]
    (expect_ok "JSON.ARRTRIM"
       (J.arr_trim c ~key ~path:"$.tags" ~start:0 ~stop:1));
  check_int_options "array length" [ Some 2 ]
    (expect_ok "JSON.ARRLEN" (J.arr_len c ~path:"$.tags" ~key));
  check_int_options "array index" [ Some 1 ]
    (expect_ok "JSON.ARRINDEX"
       (J.arr_index c ~key ~path:"$.tags" ~json:"\"poetry\""));
  Alcotest.(check (list (option string))) "array pop" [ Some "\"poetry\"" ]
    (expect_ok "JSON.ARRPOP" (J.arr_pop c ~key ~path:"$.tags" ~index:1));
  check_int_options "array length after pop" [ Some 1 ]
    (expect_ok "JSON.ARRLEN after pop"
       (J.arr_len c ~path:"$.tags" ~key));
  (match
     expect_ok "JSON.NUMINCRBY"
       (J.num_incr_by c ~key ~path:"$.age" 1.0)
   with
   | Some "[37]" -> ()
   | Some other -> Alcotest.failf "unexpected NUMINCRBY payload %S" other
   | None -> Alcotest.fail "missing NUMINCRBY payload");
  (match
     expect_ok "JSON.NUMMULTBY"
       (J.num_mult_by c ~key ~path:"$.age" 2.0)
   with
   | Some "[74]" -> ()
   | Some other -> Alcotest.failf "unexpected NUMMULTBY payload %S" other
   | None -> Alcotest.fail "missing NUMMULTBY payload");
  check_int_options "string append length" [ Some 12 ]
    (expect_ok "JSON.STRAPPEND"
       (J.str_append c ~key ~path:"$.name" "\" lovelace\""));
  check_int_options "string length" [ Some 12 ]
    (expect_ok "JSON.STRLEN" (J.strlen c ~key ~path:"$.name"));
  Alcotest.(check (list (option bool))) "toggle" [ Some false ]
    (expect_ok "JSON.TOGGLE" (J.toggle c ~key ~path:"$.active"));
  expect_ok "JSON.MSET"
    (J.mset c
       [ { J.key = key2; path = "$"; json = "{\"name\":\"grace\"}" };
         { J.key = key3; path = "$"; json = "{\"name\":\"katherine\"}" };
       ]);
  Alcotest.(check (list (option string))) "mget names"
    [ Some "[\"ada lovelace\"]"; Some "[\"grace\"]";
      Some "[\"katherine\"]"; None;
    ]
    (expect_ok "JSON.MGET"
       (J.mget c
          ~keys:[ key; key2; key3; "ocaml:json:missing" ]
          ~path:"$.name"));
  (match expect_ok "JSON.RESP" (J.resp c ~path:"$.name" ~key) with
   | R.Array _ -> ()
   | reply -> Alcotest.failf "unexpected JSON.RESP reply %a" R.pp reply);
  Alcotest.(check int) "forget count" 1
    (expect_ok "JSON.FORGET" (J.forget c ~path:"$.meta" ~key));
  Alcotest.(check int) "clear count" 1
    (expect_ok "JSON.CLEAR" (J.clear c ~path:"$.tags" ~key));
  Alcotest.(check int) "delete count" 1
    (expect_ok "JSON.DEL" (J.del c ~key));
  ignore (J.del c ~key:key2);
  ignore (J.del c ~key:key3)

let tests =
  let available = json_available () in
  let tc name f =
    if available then Alcotest.test_case name `Quick f
    else Alcotest.test_case name `Quick (skipped name)
  in
  [ tc "JSON document workflow" test_json_document_workflow ]
