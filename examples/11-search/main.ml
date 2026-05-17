module C = Valkey.Client
module S = Valkey.Search
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let index = "idx:example:books"
let prefix = "example:search:book:"

let fail_conn label e =
  Format.eprintf "%s: %a@." label E.pp e;
  exit 1

let string_of_value = function
  | R.Bulk_string s | R.Simple_string s -> s
  | R.Integer n -> Int64.to_string n
  | R.Double f -> Printf.sprintf "%.3f" f
  | R.Null -> "<null>"
  | other -> Format.asprintf "%a" R.pp other

let field name fields =
  match List.assoc_opt name fields with
  | None -> ""
  | Some value -> string_of_value value

let contains ~needle haystack =
  let n = String.length needle in
  let h = String.length haystack in
  let rec loop i =
    if i + n > h then false
    else if String.sub haystack i n = needle then true
    else loop (i + 1)
  in
  n = 0 || loop 0

let drop_if_exists client =
  match S.drop_index client index with
  | Ok () -> ()
  | Error (E.Server_error e)
    when contains ~needle:"not found" (Valkey.Error.to_string e) -> ()
  | Error e -> fail_conn "FT.DROPINDEX" e

let hset client key fields =
  match C.hset client key fields with
  | Ok _ -> ()
  | Error e -> fail_conn ("HSET " ^ key) e

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6381 ()
  in
  Fun.protect ~finally:(fun () -> C.close client) @@ fun () ->

  let doc1 = prefix ^ "1" in
  let doc2 = prefix ^ "2" in
  let doc3 = prefix ^ "3" in
  drop_if_exists client;
  ignore (C.del client [ doc1; doc2; doc3 ]);

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
  (match S.create client ~options ~index ~schema with
   | Ok () -> ()
   | Error e -> fail_conn "FT.CREATE" e);

  hset client doc1
    [ "title", "war and peace";
      "author", "tolstoy,classic";
      "year", "1869";
    ];
  hset client doc2
    [ "title", "peace talks";
      "author", "modern";
      "year", "2020";
    ];
  hset client doc3
    [ "title", "the art of computer programming";
      "author", "knuth,classic";
      "year", "1968";
    ];

  let search_options =
    { S.default_search_options with
      return_fields = Some [ S.return_field "title"; S.return_field "year" ];
      sort_by = Some (S.search_sort ~direction:S.Asc "year");
    }
  in
  (match S.search client ~options:search_options ~index ~query:"@title:peace" with
   | Ok { total; documents } ->
       Printf.printf "found %Ld matching books\n" total;
       List.iter
         (fun doc ->
           Printf.printf "- %s (%s): %s\n"
             doc.S.key
             (field "year" doc.fields)
             (field "title" doc.fields))
         documents
   | Error e -> fail_conn "FT.SEARCH" e);

  let aggregate_options =
    { S.default_aggregate_options with
      load = Some (S.Load_fields [ "author"; "year" ]);
      stages =
        [ S.Sort_by
            { fields = [ S.aggregate_sort ~direction:S.Asc "@year" ];
              max = None;
            };
          S.Limit { offset = 0; count = 3 };
        ];
    }
  in
  (match
     S.aggregate client ~options:aggregate_options ~index
       ~query:"@author:{classic}"
   with
   | Ok { rows; _ } ->
       Printf.printf "\noldest classic rows\n";
       List.iter
         (fun row ->
           Printf.printf "- %s: %s\n"
             (field "year" row)
             (field "author" row))
         rows
   | Error e -> fail_conn "FT.AGGREGATE" e);

  drop_if_exists client;
  ignore (C.del client [ doc1; doc2; doc3 ])
