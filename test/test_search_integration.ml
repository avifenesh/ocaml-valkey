module C = Valkey.Client
module S = Valkey.Search
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let host = "localhost"

let port () =
  match Sys.getenv_opt "VALKEY_SEARCH_PORT" with
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

let search_available () =
  try
    with_client @@ fun c ->
    match S.list_indexes c with
    | Ok _ -> true
    | Error _ -> false
  with _ -> false

let skipped name () =
  Printf.printf
    "[skipped] %s (need valkey-bundle on localhost:%d; \
     docker compose -f docker-compose.search.yml up -d, or set \
     VALKEY_SEARCH_PORT to override)\n%!"
    name (port ())

let get_field name doc =
  match List.assoc_opt name doc.S.fields with
  | Some (R.Bulk_string s) | Some (R.Simple_string s) -> Some s
  | Some other -> Alcotest.failf "field %s: unexpected %a" name R.pp other
  | None -> None

let has_field name doc = List.mem_assoc name doc.S.fields

let contains ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

let drop_ignoring_missing c index =
  match S.drop_index c index with
  | Ok () -> ()
  | Error (E.Server_error e)
    when contains ~needle:"not found" (Valkey.Error.to_string e) -> ()
  | Error e -> Alcotest.failf "cleanup FT.DROPINDEX: %a" err_pp e

let expect_ok ctx = function
  | Ok (R.Simple_string "OK") | Ok (R.Bulk_string "OK") -> ()
  | Ok other -> Alcotest.failf "%s: unexpected %a" ctx R.pp other
  | Error e -> Alcotest.failf "%s: %a" ctx err_pp e

let json_set c key payload =
  expect_ok ("JSON.SET " ^ key)
    (C.custom c [| "JSON.SET"; key; "$"; payload |])

let float32_blob values =
  let bytes = Bytes.create (List.length values * 4) in
  let set_byte offset bits shift =
    let byte =
      Int32.(to_int (logand (shift_right_logical bits shift) 0xffl))
    in
    Bytes.set bytes offset (Char.chr byte)
  in
  List.iteri
    (fun i value ->
      let bits = Int32.bits_of_float value in
      let offset = i * 4 in
      set_byte offset bits 0;
      set_byte (offset + 1) bits 8;
      set_byte (offset + 2) bits 16;
      set_byte (offset + 3) bits 24)
    values;
  Bytes.unsafe_to_string bytes

let test_hash_search_round_trip () =
  with_client @@ fun c ->
  let index = "idx:ocaml:search" in
  let prefix = "ocaml:search:doc:" in
  let doc1 = prefix ^ "1" in
  let doc2 = prefix ^ "2" in
  drop_ignoring_missing c index;
  ignore (C.del c [ doc1; doc2 ]);
  let options =
    { S.default_create_options with
      prefixes = [ prefix ];
    }
  in
  let schema =
    [ S.text "title";
      S.tag ~separator:',' "author";
      S.numeric ~sortable:true "year";
    ]
  in
  (match S.create c ~options ~index ~schema with
   | Ok () -> ()
   | Error e -> Alcotest.failf "FT.CREATE: %a" err_pp e);
  (match
     C.hset c doc1
       [ "title", "war and peace";
         "author", "tolstoy,classic";
         "year", "1869";
       ]
   with
   | Ok 3 -> ()
   | Ok n -> Alcotest.failf "HSET doc1: expected 3, got %d" n
   | Error e -> Alcotest.failf "HSET doc1: %a" err_pp e);
  (match
     C.hset c doc2
       [ "title", "peace talks";
         "author", "modern";
         "year", "2020";
       ]
   with
   | Ok 3 -> ()
   | Ok n -> Alcotest.failf "HSET doc2: expected 3, got %d" n
   | Error e -> Alcotest.failf "HSET doc2: %a" err_pp e);
  let search_options =
    { S.default_search_options with
      return_fields = Some [ S.return_field "title"; S.return_field "year" ];
      sort_by = Some (S.search_sort ~direction:S.Asc "year");
      limit = Some (0, 10);
    }
  in
  (match S.search c ~options:search_options ~index ~query:"@title:peace" with
   | Ok { total = 2L; documents = [ first; second ] } ->
       Alcotest.(check string) "first key" doc1 first.key;
       Alcotest.(check string) "second key" doc2 second.key;
       Alcotest.(check (option string)) "first title"
         (Some "war and peace") (get_field "title" first);
       Alcotest.(check (option string)) "second year"
         (Some "2020") (get_field "year" second)
   | Ok r ->
       Alcotest.failf "unexpected search total=%Ld docs=%d"
         r.total (List.length r.documents)
   | Error e -> Alcotest.failf "FT.SEARCH: %a" err_pp e);
  (match S.info_raw c index with
   | Ok info ->
       Alcotest.(check bool) "FT.INFO has state" true
         (List.mem_assoc "state" info)
   | Error e -> Alcotest.failf "FT.INFO: %a" err_pp e);
  (match S.list_indexes c with
   | Ok indexes ->
       Alcotest.(check bool) "FT._LIST contains index" true
         (List.exists (( = ) index) indexes)
   | Error e -> Alcotest.failf "FT._LIST: %a" err_pp e);
  let aggregate_options =
    { S.default_aggregate_options with
      load = Some (S.Load_fields [ "author"; "year" ]);
      stages =
        [ S.Sort_by
            { fields = [ S.aggregate_sort ~direction:S.Asc "@year" ];
              max = None;
            };
          S.Limit { offset = 0; count = 2 };
        ];
    }
  in
  (match
     S.aggregate c ~options:aggregate_options ~index
       ~query:"@title:peace"
   with
   | Ok { rows = [ row1; row2 ]; _ } ->
       Alcotest.(check bool) "row1 year" true (List.mem_assoc "year" row1);
       Alcotest.(check bool) "row2 author" true (List.mem_assoc "author" row2)
   | Ok r ->
       Alcotest.failf "unexpected aggregate rows=%d" (List.length r.rows)
   | Error e -> Alcotest.failf "FT.AGGREGATE: %a" err_pp e);
  (match S.drop_index c index with
   | Ok () -> ()
   | Error e -> Alcotest.failf "FT.DROPINDEX: %a" err_pp e);
  ignore (C.del c [ doc1; doc2 ])

let test_json_vector_search_round_trip () =
  with_client @@ fun c ->
  let index = "idx:ocaml:search:json" in
  let prefix = "ocaml:search:json:" in
  let doc1 = prefix ^ "1" in
  let doc2 = prefix ^ "2" in
  drop_ignoring_missing c index;
  ignore (C.del c [ doc1; doc2 ]);
  let options =
    { S.default_create_options with
      data_type = S.Json;
      prefixes = [ prefix ];
    }
  in
  let schema =
    [ S.text ~alias:"title" "$.title";
      S.vector_flat ~alias:"embedding" "$.embedding"
        ~dim:2 ~distance_metric:S.L2;
    ]
  in
  (match S.create c ~options ~index ~schema with
   | Ok () -> ()
   | Error e -> Alcotest.failf "JSON FT.CREATE: %a" err_pp e);
  json_set c doc1
    "{\"title\":\"calm harbor\",\"embedding\":[0.0,0.0]}";
  json_set c doc2
    "{\"title\":\"distant ridge\",\"embedding\":[3.0,4.0]}";
  let title_options =
    { S.default_search_options with
      return_fields = Some [ S.return_field "title" ];
      limit = Some (0, 10);
    }
  in
  (match S.search c ~options:title_options ~index ~query:"@title:calm" with
   | Ok { documents = [ doc ]; _ } ->
       Alcotest.(check string) "JSON doc key" doc1 doc.key;
       (match get_field "title" doc with
        | Some title ->
            Alcotest.(check bool) "JSON title returned" true
              (contains ~needle:"calm" title)
        | None -> Alcotest.fail "missing JSON title field")
   | Ok r ->
       Alcotest.failf "unexpected JSON search docs=%d"
         (List.length r.documents)
   | Error e -> Alcotest.failf "JSON FT.SEARCH: %a" err_pp e);
  let vector_options =
    { S.default_search_options with
      dialect = Some 2;
      params = [ "q", float32_blob [ 0.0; 0.0 ] ];
      return_fields =
        Some [ S.return_field "title"; S.return_field "dist" ];
      limit = Some (0, 1);
    }
  in
  (match
     S.search c ~options:vector_options ~index
       ~query:"*=>[KNN 1 @embedding $q AS dist]"
   with
   | Ok { documents = [ doc ]; _ } ->
       Alcotest.(check string) "nearest vector doc" doc1 doc.key;
       Alcotest.(check bool) "distance field returned" true
         (has_field "dist" doc)
   | Ok r ->
       Alcotest.failf "unexpected vector search docs=%d"
         (List.length r.documents)
   | Error e -> Alcotest.failf "vector FT.SEARCH: %a" err_pp e);
  (match S.drop_index c index with
   | Ok () -> ()
   | Error e -> Alcotest.failf "JSON FT.DROPINDEX: %a" err_pp e);
  ignore (C.del c [ doc1; doc2 ])

let tests =
  let available = search_available () in
  let tc name f =
    if available then Alcotest.test_case name `Quick f
    else Alcotest.test_case name `Quick (skipped name)
  in
  [ tc "hash index create/search/info/list/aggregate/drop"
      test_hash_search_round_trip;
    tc "JSON index and vector KNN round-trip"
      test_json_vector_search_round_trip;
  ]
