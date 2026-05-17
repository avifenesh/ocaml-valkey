module S = Valkey.Search
module R = Valkey.Resp3
module E = Valkey.Connection.Error
module C = Valkey.Client
module Router = Valkey.Router
module T = Valkey.Router.Target
module RF = Valkey.Router.Read_from

let array_check name expected actual =
  Alcotest.(check (list string)) name (Array.to_list expected)
    (Array.to_list actual)

let fake_client ?error ?(reply = R.Null) () =
  let seen = ref None in
  let exec ?timeout:_ target rf args =
    seen := Some (target, rf, Array.to_list args);
    match error with
    | Some e -> Error e
    | None -> Ok reply
  in
  let exec_multi ?timeout:_ _fan _args = [] in
  let pair ?timeout:_ _target _args1 _args2 =
    Error (E.Terminal "unused")
  in
  let router =
    Router.make ~exec ~exec_multi ~pair ~close:(fun () -> ())
      ~primary:(fun () -> None)
      ~connection_for_slot:(fun _ -> None)
      ~endpoint_for_slot:(fun _ -> None)
      ~endpoint_for_node:(fun ~node_id:_ -> None)
      ~all_connections:(fun () -> [])
      ~is_standalone:false
      ~atomic_lock_for_slot:(fun _ -> Eio.Mutex.create ())
  in
  (C.from_router ~config:C.Config.default router, seen)

let check_seen name ~read_from ~args seen =
  match !seen with
  | Some (T.Random, rf, got) when rf = read_from && got = args -> ()
  | Some _ ->
      Alcotest.fail
        (name ^ " routed with unexpected target/read policy/args")
  | None -> Alcotest.fail (name ^ " did not call fake router")

let expect_protocol_violation name = function
  | Error (E.Protocol_violation _) -> ()
  | Ok _ -> Alcotest.fail (name ^ " should reject the reply shape")
  | Error e ->
      Alcotest.failf "%s: expected protocol violation, got %a" name E.pp e

let expect_terminal name = function
  | Error (E.Terminal "wire closed") -> ()
  | Ok _ -> Alcotest.fail (name ^ " should pass through transport errors")
  | Error e -> Alcotest.failf "%s: unexpected transport error %a" name E.pp e

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

let test_create_args_additional_variants () =
  let options =
    { S.default_create_options with stopwords = No_stopwords }
  in
  let schema =
    [ S.text ~suffix_trie:S.With_suffix_trie "title";
      S.vector_flat "embedding" ~dim:2 ~distance_metric:S.L2;
      S.vector_hnsw "ann" ~dim:8 ~distance_metric:S.Ip
        ~initial_cap:128;
    ]
  in
  let args = S.For_testing.create_args ~options ~index:"idx:more" ~schema in
  array_check "FT.CREATE extra variants"
    [| "FT.CREATE"; "idx:more"; "ON"; "HASH";
       "NOSTOPWORDS";
       "SCHEMA";
       "title"; "TEXT"; "WITHSUFFIXTRIE";
       "embedding"; "VECTOR"; "FLAT"; "6"; "TYPE"; "FLOAT32";
       "DIM"; "2"; "DISTANCE_METRIC"; "L2";
       "ann"; "VECTOR"; "HNSW"; "8"; "TYPE"; "FLOAT32";
       "DIM"; "8"; "DISTANCE_METRIC"; "IP"; "INITIAL_CAP"; "128";
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

let test_search_args_return_none_and_sort_without_direction () =
  let options =
    { S.default_search_options with
      no_content = true;
      return_fields = Some [];
      sort_by = Some (S.search_sort "score");
    }
  in
  let args =
    S.For_testing.search_args ~options ~index:"idx:books"
      ~query:"*"
  in
  array_check "FT.SEARCH args with empty return and default sort"
    [| "FT.SEARCH"; "idx:books"; "*";
       "ALLSHARDS"; "CONSISTENT";
       "NOCONTENT";
       "RETURN"; "0";
       "SORTBY"; "score";
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

let test_decode_search_no_content_with_sort_keys () =
  let options =
    { S.default_search_options with
      no_content = true;
      with_sort_keys = true;
    }
  in
  let reply =
    R.Array
      [ R.Integer 2L;
        R.Bulk_string "doc:1";
        R.Bulk_string "#1869";
        R.Bulk_string "doc:2";
        R.Bulk_string "#2020";
      ]
  in
  match S.For_testing.decode_search ~options reply with
  | Ok
      { total = 2L;
        documents =
          [ { key = "doc:1"; sort_key = Some (R.Bulk_string "#1869"); fields = [] };
            { key = "doc:2"; sort_key = Some (R.Bulk_string "#2020"); fields = [] };
          ];
      } ->
      ()
  | Ok _ -> Alcotest.fail "unexpected no-content sort-key result"
  | Error e -> Alcotest.failf "decode no-content sort keys: %a" E.pp e

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

let test_decode_search_resp3_map_fields () =
  let reply =
    R.Array
      [ R.Integer 1L;
        R.Bulk_string "doc:1";
        R.Map
          [ R.Bulk_string "title", R.Bulk_string "war and peace";
            R.Bulk_string "year", R.Bulk_string "1869";
          ];
      ]
  in
  match S.For_testing.decode_search ~options:S.default_search_options reply with
  | Ok { total = 1L; documents = [ { key = "doc:1"; fields; _ } ] } ->
      Alcotest.(check int) "map fields" 2 (List.length fields);
      Alcotest.(check (option string)) "title"
        (Some "war and peace")
        (match List.assoc_opt "title" fields with
         | Some (R.Bulk_string s) -> Some s
         | _ -> None)
  | Ok _ -> Alcotest.fail "unexpected RESP3 map search result"
  | Error e -> Alcotest.failf "decode map fields: %a" E.pp e

let test_search_wrappers_route_and_decode () =
  let client, seen = fake_client ~reply:(R.Bulk_string "OK") () in
  (match S.create client ~index:"idx" ~schema:[ S.text "title" ] with
   | Ok () -> ()
   | Error e -> Alcotest.failf "FT.CREATE: %a" E.pp e);
  check_seen "FT.CREATE" ~read_from:RF.Primary
    ~args:[ "FT.CREATE"; "idx"; "ON"; "HASH"; "SCHEMA"; "title"; "TEXT" ]
    seen;

  let client, seen = fake_client ~reply:(R.Simple_string "OK") () in
  (match S.drop_index client "idx" with
   | Ok () -> ()
   | Error e -> Alcotest.failf "FT.DROPINDEX: %a" E.pp e);
  check_seen "FT.DROPINDEX" ~read_from:RF.Primary
    ~args:[ "FT.DROPINDEX"; "idx" ] seen;

  let client, seen =
    fake_client
      ~reply:
        (R.Set
           [ R.Bulk_string "idx";
             R.Simple_string "other";
             R.Verbatim_string { encoding = "txt"; data = "verbatim" };
           ])
      ()
  in
  (match S.list_indexes ~read_from:RF.Prefer_replica client with
   | Ok [ "idx"; "other"; "verbatim" ] -> ()
   | Ok indexes ->
       Alcotest.failf "unexpected FT._LIST payload: %s"
         (String.concat "," indexes)
   | Error e -> Alcotest.failf "FT._LIST: %a" E.pp e);
  check_seen "FT._LIST" ~read_from:RF.Prefer_replica
    ~args:[ "FT._LIST" ] seen;

  let client, seen =
    fake_client
      ~reply:
        (R.Map
           [ R.Bulk_string "index_name", R.Bulk_string "idx";
             R.Bulk_string "num_docs", R.Integer 2L;
           ])
      ()
  in
  let info_options =
    { S.scope = Cluster;
      shard_policy = Some_shards;
      consistency = Inconsistent;
    }
  in
  (match S.info_raw ~read_from:RF.Prefer_replica ~options:info_options client "idx" with
   | Ok [ "index_name", R.Bulk_string "idx"; "num_docs", R.Integer 2L ] -> ()
   | Ok _ -> Alcotest.fail "unexpected FT.INFO payload"
   | Error e -> Alcotest.failf "FT.INFO: %a" E.pp e);
  check_seen "FT.INFO" ~read_from:RF.Prefer_replica
    ~args:[ "FT.INFO"; "idx"; "CLUSTER"; "SOMESHARDS"; "INCONSISTENT" ]
    seen;

  let client, seen =
    fake_client
      ~reply:
        (R.Array
           [ R.Integer 1L;
             R.Bulk_string "doc:1";
             R.Array [ R.Bulk_string "title"; R.Bulk_string "peace" ];
           ])
      ()
  in
  (match S.search ~read_from:RF.Prefer_replica client ~index:"idx" ~query:"*" with
   | Ok { total = 1L; documents = [ { key = "doc:1"; _ } ] } -> ()
   | Ok _ -> Alcotest.fail "unexpected FT.SEARCH payload"
   | Error e -> Alcotest.failf "FT.SEARCH: %a" E.pp e);
  check_seen "FT.SEARCH" ~read_from:RF.Prefer_replica
    ~args:[ "FT.SEARCH"; "idx"; "*"; "ALLSHARDS"; "CONSISTENT" ]
    seen;

  let client, seen =
    fake_client
      ~reply:
        (R.Array
           [ R.Integer 1L;
             R.Array [ R.Bulk_string "count"; R.Integer 1L ];
           ])
      ()
  in
  (match S.aggregate client ~index:"idx" ~query:"*" with
   | Ok { rows = [ [ "count", R.Integer 1L ] ]; _ } -> ()
   | Ok _ -> Alcotest.fail "unexpected FT.AGGREGATE payload"
   | Error e -> Alcotest.failf "FT.AGGREGATE: %a" E.pp e);
  check_seen "FT.AGGREGATE" ~read_from:RF.Primary
    ~args:[ "FT.AGGREGATE"; "idx"; "*" ] seen

let test_search_wrappers_pass_through_transport_errors () =
  let transport = E.Terminal "wire closed" in
  let client, _seen = fake_client ~error:transport () in
  expect_terminal "FT.CREATE transport"
    (S.create client ~index:"idx" ~schema:[ S.text "title" ]);
  expect_terminal "FT.DROPINDEX transport" (S.drop_index client "idx");
  expect_terminal "FT._LIST transport" (S.list_indexes client);
  expect_terminal "FT.INFO transport" (S.info_raw client "idx");
  expect_terminal "FT.SEARCH transport"
    (S.search client ~index:"idx" ~query:"*");
  expect_terminal "FT.AGGREGATE transport"
    (S.aggregate client ~index:"idx" ~query:"*")

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

let test_decode_search_rejects_more_bad_shapes () =
  expect_protocol_violation "FT.SEARCH scalar"
    (S.For_testing.decode_search ~options:S.default_search_options
       (R.Integer 1L));
  expect_protocol_violation "FT.SEARCH bad key"
    (S.For_testing.decode_search ~options:S.default_search_options
       (R.Array [ R.Integer 1L; R.Integer 42L; R.Array [] ]));
  let no_content_sort_keys =
    { S.default_search_options with no_content = true; with_sort_keys = true }
  in
  expect_protocol_violation "FT.SEARCH missing sort key"
    (S.For_testing.decode_search ~options:no_content_sort_keys
       (R.Array [ R.Integer 1L; R.Bulk_string "doc:1" ]));
  let with_sort_keys =
    { S.default_search_options with with_sort_keys = true }
  in
  expect_protocol_violation "FT.SEARCH malformed sort-key row"
    (S.For_testing.decode_search ~options:with_sort_keys
       (R.Array
          [ R.Integer 1L; R.Bulk_string "doc:1"; R.Integer 1L ]))

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

let test_info_raw_rejects_bad_shapes () =
  expect_protocol_violation "FT.INFO odd array"
    (S.For_testing.decode_info_raw (R.Array [ R.Bulk_string "index_name" ]));
  expect_protocol_violation "FT.INFO bad map key"
    (S.For_testing.decode_info_raw
       (R.Map [ R.Integer 1L, R.Bulk_string "idx" ]));
  expect_protocol_violation "FT.INFO scalar"
    (S.For_testing.decode_info_raw (R.Integer 1L))

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

let test_aggregate_args_additional_variants () =
  let options : S.aggregate_options =
    {
      dialect = Some 3;
      inorder = true;
      load = Some S.Load_all;
      params = [ "needle", "peace" ];
      slop = Some 2;
      timeout_ms = Some 100;
      verbatim = true;
      stages =
        [ S.Apply { expression = "upper(@title)"; alias = "TITLE" };
          S.Filter "@year >= 1900";
          S.Group_by
            { fields = [];
              reducers =
                [ S.group_reducer (S.Count_distinct "@author");
                  S.group_reducer (S.Sum "@price");
                  S.group_reducer (S.Min "@price");
                  S.group_reducer (S.Max "@price");
                  S.group_reducer (S.Stddev "@price");
                  S.group_reducer
                    (S.Custom_reducer
                       { name = "QUANTILE"; args = [ "@price"; "0.95" ] });
                ];
            };
          S.Sort_by
            { fields =
                [ S.aggregate_sort "@score";
                  S.aggregate_sort ~direction:S.Asc "@year";
                ];
              max = None;
            };
          S.Limit { offset = 5; count = 10 };
        ];
    }
  in
  let args =
    S.For_testing.aggregate_args ~options ~index:"idx:books"
      ~query:"@title:$needle"
  in
  array_check "FT.AGGREGATE args with extra variants"
    [| "FT.AGGREGATE"; "idx:books"; "@title:$needle";
       "DIALECT"; "3";
       "INORDER";
       "LOAD"; "*";
       "PARAMS"; "2"; "needle"; "peace";
       "SLOP"; "2";
       "TIMEOUT"; "100";
       "VERBATIM";
       "APPLY"; "upper(@title)"; "AS"; "TITLE";
       "FILTER"; "@year >= 1900";
       "GROUPBY"; "0";
       "REDUCE"; "COUNT_DISTINCT"; "1"; "@author";
       "REDUCE"; "SUM"; "1"; "@price";
       "REDUCE"; "MIN"; "1"; "@price";
       "REDUCE"; "MAX"; "1"; "@price";
       "REDUCE"; "STDDEV"; "1"; "@price";
       "REDUCE"; "QUANTILE"; "2"; "@price"; "0.95";
       "SORTBY"; "3"; "@score"; "@year"; "ASC";
       "LIMIT"; "5"; "10";
    |]
    args

let test_decode_aggregate_resp3_map_rows () =
  let reply =
    R.Array
      [ R.Integer 1L;
        R.Map
          [ R.Bulk_string "author", R.Bulk_string "modern";
            R.Bulk_string "count", R.Integer 3L;
          ];
      ]
  in
  match S.For_testing.decode_aggregate reply with
  | Ok { header = R.Integer 1L; rows = [ row ] } ->
      Alcotest.(check int) "map row fields" 2 (List.length row);
      Alcotest.(check (option int64)) "count"
        (Some 3L)
        (match List.assoc_opt "count" row with
         | Some (R.Integer n) -> Some n
         | _ -> None)
  | Ok _ -> Alcotest.fail "unexpected RESP3 map aggregate result"
  | Error e -> Alcotest.failf "aggregate map decode: %a" E.pp e

let test_decode_aggregate_rejects_bad_shapes () =
  expect_protocol_violation "FT.AGGREGATE scalar"
    (S.For_testing.decode_aggregate (R.Integer 1L));
  expect_protocol_violation "FT.AGGREGATE bad row"
    (S.For_testing.decode_aggregate
       (R.Array [ R.Integer 1L; R.Integer 2L ]))

let tests =
  [ Alcotest.test_case "FT.CREATE args cover schema options" `Quick
      test_create_args_full_schema;
    Alcotest.test_case "FT.CREATE args cover extra variants" `Quick
      test_create_args_additional_variants;
    Alcotest.test_case "VECTOR FLAT attr count" `Quick
      test_vector_flat_arg_count;
    Alcotest.test_case "FT.SEARCH args cover query options" `Quick
      test_search_args;
    Alcotest.test_case "FT.SEARCH args cover empty return" `Quick
      test_search_args_return_none_and_sort_without_direction;
    Alcotest.test_case "decode FT.SEARCH with content" `Quick
      test_decode_search_content;
    Alcotest.test_case "decode FT.SEARCH NOCONTENT" `Quick
      test_decode_search_no_content;
    Alcotest.test_case "decode FT.SEARCH NOCONTENT WITHSORTKEYS" `Quick
      test_decode_search_no_content_with_sort_keys;
    Alcotest.test_case "decode FT.SEARCH WITHSORTKEYS" `Quick
      test_decode_search_with_sort_keys;
    Alcotest.test_case "decode FT.SEARCH RESP3 map fields" `Quick
      test_decode_search_resp3_map_fields;
    Alcotest.test_case "Search wrappers route and decode replies" `Quick
      test_search_wrappers_route_and_decode;
    Alcotest.test_case "Search wrappers pass through transport errors" `Quick
      test_search_wrappers_pass_through_transport_errors;
    Alcotest.test_case "decode rejects odd field arrays" `Quick
      test_decode_search_rejects_odd_fields;
    Alcotest.test_case "decode rejects more bad search shapes" `Quick
      test_decode_search_rejects_more_bad_shapes;
    Alcotest.test_case "decode FT.INFO raw pairs" `Quick
      test_info_raw_decoding;
    Alcotest.test_case "decode FT.INFO rejects bad shapes" `Quick
      test_info_raw_rejects_bad_shapes;
    Alcotest.test_case "FT.AGGREGATE args and decode" `Quick
      test_aggregate_args_and_decode;
    Alcotest.test_case "FT.AGGREGATE args extra variants" `Quick
      test_aggregate_args_additional_variants;
    Alcotest.test_case "decode FT.AGGREGATE RESP3 map rows" `Quick
      test_decode_aggregate_resp3_map_rows;
    Alcotest.test_case "decode FT.AGGREGATE rejects bad shapes" `Quick
      test_decode_aggregate_rejects_bad_shapes;
  ]
