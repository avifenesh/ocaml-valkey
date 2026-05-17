module S = Valkey.Search
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let array_check name expected actual =
  Alcotest.(check (list string)) name (Array.to_list expected)
    (Array.to_list actual)

let test_create_args_full_schema () =
  let options : S.create_options =
    { data_type = Json;
      prefixes = [ "doc:"; "book:" ];
      score = Some 1.0;
      language = Some "english";
      min_stem_size = Some 5;
      offsets = No_offsets;
      stopwords = Stopwords [ "a"; "the" ];
      punctuation = Some ".,";
      skip_initial_scan = true;
    }
  in
  let schema =
    [ S.text ~alias:"title_text" ~sortable:true ~no_stem:true
        ~suffix_trie:S.No_suffix_trie ~weight:1.0 "$.title";
      S.tag ~separator:'|' ~case_sensitive:true "$.author";
      S.numeric ~sortable:true "$.year";
      S.vector_hnsw "$.embedding" ~dim:3 ~distance_metric:S.Cosine
        ~m:8 ~ef_construction:100 ~ef_runtime:20;
    ]
  in
  let args = S.For_testing.create_args ~options ~index:"idx:books" ~schema in
  array_check "FT.CREATE args"
    [| "FT.CREATE"; "idx:books"; "ON"; "JSON";
       "PREFIX"; "2"; "doc:"; "book:";
       "SCORE"; "1";
       "LANGUAGE"; "english";
       "SKIPINITIALSCAN";
       "MINSTEMSIZE"; "5";
       "NOOFFSETS";
       "STOPWORDS"; "2"; "a"; "the";
       "PUNCTUATION"; ".,";
       "SCHEMA";
       "$.title"; "AS"; "title_text"; "TEXT"; "NOSTEM";
       "NOSUFFIXTRIE"; "WEIGHT"; "1"; "SORTABLE";
       "$.author"; "TAG"; "SEPARATOR"; "|"; "CASESENSITIVE";
       "$.year"; "NUMERIC"; "SORTABLE";
       "$.embedding"; "VECTOR"; "HNSW"; "12"; "TYPE"; "FLOAT32";
       "DIM"; "3"; "DISTANCE_METRIC"; "COSINE"; "M"; "8";
       "EF_CONSTRUCTION"; "100"; "EF_RUNTIME"; "20";
    |]
    args

let test_vector_flat_arg_count () =
  let schema =
    [ S.vector_flat "embedding" ~dim:1536 ~distance_metric:S.Ip
        ~initial_cap:1000;
    ]
  in
  let args =
    S.For_testing.create_args ~options:S.default_create_options
      ~index:"idx:v" ~schema
  in
  array_check "FLAT attr count"
    [| "FT.CREATE"; "idx:v"; "ON"; "HASH"; "SCHEMA";
       "embedding"; "VECTOR"; "FLAT"; "8"; "TYPE"; "FLOAT32";
       "DIM"; "1536"; "DISTANCE_METRIC"; "IP";
       "INITIAL_CAP"; "1000";
    |]
    args

let test_search_args () =
  let options =
    { S.default_search_options with
      shard_policy = Some_shards;
      consistency = Inconsistent;
      dialect = Some 2;
      inorder = true;
      limit = Some (10, 25);
      params = [ "vec", "\000\000"; "term", "peace" ];
      return_fields =
        Some [ S.return_field "title"; S.return_field ~alias:"y" "year" ];
      slop = Some 3;
      sort_by = Some (S.search_sort ~direction:S.Desc "year");
      timeout_ms = Some 250;
      verbatim = true;
      with_sort_keys = true;
    }
  in
  let args =
    S.For_testing.search_args ~options ~index:"idx:books"
      ~query:"@title:$term"
  in
  array_check "FT.SEARCH args"
    [| "FT.SEARCH"; "idx:books"; "@title:$term";
       "SOMESHARDS"; "INCONSISTENT";
       "DIALECT"; "2";
       "INORDER";
       "LIMIT"; "10"; "25";
       "PARAMS"; "4"; "vec"; "\000\000"; "term"; "peace";
       "RETURN"; "2"; "title"; "year"; "AS"; "y";
       "SLOP"; "3";
       "SORTBY"; "year"; "DESC";
       "TIMEOUT"; "250";
       "VERBATIM";
       "WITHSORTKEYS";
    |]
    args

let test_decode_search_content () =
  let reply =
    R.Array
      [ R.Integer 2L;
        R.Bulk_string "doc:1";
        R.Array
          [ R.Bulk_string "title"; R.Bulk_string "war and peace";
            R.Bulk_string "year"; R.Bulk_string "1869";
          ];
        R.Bulk_string "doc:2";
        R.Array
          [ R.Bulk_string "title"; R.Bulk_string "peace talks";
            R.Bulk_string "year"; R.Bulk_string "2020";
          ];
      ]
  in
  match S.For_testing.decode_search ~options:S.default_search_options reply with
  | Ok { total = 2L; documents = [ d1; d2 ] } ->
      Alcotest.(check string) "doc1 key" "doc:1" d1.key;
      Alcotest.(check string) "doc2 key" "doc:2" d2.key;
      Alcotest.(check int) "doc1 fields" 2 (List.length d1.fields)
  | Ok _ -> Alcotest.fail "unexpected search result shape"
  | Error e -> Alcotest.failf "decode search: %a" E.pp e

let test_decode_search_no_content () =
  let options = { S.default_search_options with no_content = true } in
  let reply =
    R.Array
      [ R.Integer 2L; R.Bulk_string "doc:1"; R.Bulk_string "doc:2" ]
  in
  match S.For_testing.decode_search ~options reply with
  | Ok { total = 2L; documents = [ d1; d2 ] } ->
      Alcotest.(check string) "doc1 key" "doc:1" d1.key;
      Alcotest.(check int) "doc1 no fields" 0 (List.length d1.fields);
      Alcotest.(check string) "doc2 key" "doc:2" d2.key
  | Ok _ -> Alcotest.fail "unexpected no-content result"
  | Error e -> Alcotest.failf "decode no-content: %a" E.pp e

let test_decode_search_with_sort_keys () =
  let options =
    { S.default_search_options with
      sort_by = Some (S.search_sort ~direction:S.Asc "year");
      with_sort_keys = true;
    }
  in
  let reply =
    R.Array
      [ R.Integer 1L;
        R.Bulk_string "doc:1";
        R.Bulk_string "#1869";
        R.Array [ R.Bulk_string "year"; R.Bulk_string "1869" ];
      ]
  in
  match S.For_testing.decode_search ~options reply with
  | Ok { documents = [ { sort_key = Some (R.Bulk_string "#1869"); _ } ]; _ } ->
      ()
  | Ok _ -> Alcotest.fail "expected decoded sort key"
  | Error e -> Alcotest.failf "decode sort key: %a" E.pp e

let test_decode_search_rejects_odd_fields () =
  let reply =
    R.Array
      [ R.Integer 1L;
        R.Bulk_string "doc:1";
        R.Array [ R.Bulk_string "title" ];
      ]
  in
  match S.For_testing.decode_search ~options:S.default_search_options reply with
  | Error (E.Protocol_violation _) -> ()
  | Ok _ -> Alcotest.fail "expected protocol violation"
  | Error e -> Alcotest.failf "expected protocol violation, got %a" E.pp e

let test_info_raw_decoding () =
  let reply =
    R.Array
      [ R.Bulk_string "index_name"; R.Bulk_string "idx";
        R.Bulk_string "num_docs"; R.Integer 2L;
      ]
  in
  match S.For_testing.decode_info_raw reply with
  | Ok [ "index_name", R.Bulk_string "idx"; "num_docs", R.Integer 2L ] -> ()
  | Ok _ -> Alcotest.fail "unexpected info pairs"
  | Error e -> Alcotest.failf "info decode: %a" E.pp e

let test_aggregate_args_and_decode () =
  let options =
    { S.default_aggregate_options with
      load = Some (S.Load_fields [ "author"; "year" ]);
      stages =
        [ S.Group_by
            { fields = [ "@author" ];
              reducers =
                [ S.group_reducer ~alias:"count" S.Count;
                  S.group_reducer ~alias:"avg_year" (S.Avg "@year");
                ];
            };
          S.Sort_by
            { fields = [ S.aggregate_sort ~direction:S.Desc "@avg_year" ];
              max = Some 10;
            };
          S.Limit { offset = 0; count = 5 };
        ];
    }
  in
  let args =
    S.For_testing.aggregate_args ~options ~index:"idx:books"
      ~query:"@title:peace"
  in
  array_check "FT.AGGREGATE args"
    [| "FT.AGGREGATE"; "idx:books"; "@title:peace";
       "LOAD"; "2"; "author"; "year";
       "GROUPBY"; "1"; "@author";
       "REDUCE"; "COUNT"; "0"; "AS"; "count";
       "REDUCE"; "AVG"; "1"; "@year"; "AS"; "avg_year";
       "SORTBY"; "2"; "@avg_year"; "DESC"; "MAX"; "10";
       "LIMIT"; "0"; "5";
    |]
    args;
  let reply =
    R.Array
      [ R.Integer 2L;
        R.Array
          [ R.Bulk_string "author"; R.Bulk_string "modern";
            R.Bulk_string "count"; R.Bulk_string "1";
          ];
      ]
  in
  match S.For_testing.decode_aggregate reply with
  | Ok { header = R.Integer 2L; rows = [ row ] } ->
      Alcotest.(check int) "row fields" 2 (List.length row)
  | Ok _ -> Alcotest.fail "unexpected aggregate result"
  | Error e -> Alcotest.failf "aggregate decode: %a" E.pp e

let tests =
  [ Alcotest.test_case "FT.CREATE args cover schema options" `Quick
      test_create_args_full_schema;
    Alcotest.test_case "VECTOR FLAT attr count" `Quick
      test_vector_flat_arg_count;
    Alcotest.test_case "FT.SEARCH args cover query options" `Quick
      test_search_args;
    Alcotest.test_case "decode FT.SEARCH with content" `Quick
      test_decode_search_content;
    Alcotest.test_case "decode FT.SEARCH NOCONTENT" `Quick
      test_decode_search_no_content;
    Alcotest.test_case "decode FT.SEARCH WITHSORTKEYS" `Quick
      test_decode_search_with_sort_keys;
    Alcotest.test_case "decode rejects odd field arrays" `Quick
      test_decode_search_rejects_odd_fields;
    Alcotest.test_case "decode FT.INFO raw pairs" `Quick
      test_info_raw_decoding;
    Alcotest.test_case "FT.AGGREGATE args and decode" `Quick
      test_aggregate_args_and_decode;
  ]
