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
      skip_initial_scan = true;
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

let tests =
  let available = search_available () in
  let tc name f =
    if available then Alcotest.test_case name `Quick f
    else Alcotest.test_case name `Quick (skipped name)
  in
  [ tc "hash index create/search/info/list/aggregate/drop"
      test_hash_search_round_trip;
  ]
