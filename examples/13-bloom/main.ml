module C = Valkey.Client
module B = Valkey.Bloom
module E = Valkey.Connection.Error

let key = "example:bloom:emails"
let campaign_key = "example:bloom:campaign"
let nonscaling_key = "example:bloom:nonscaling"

let fail_conn label e =
  Format.eprintf "%s: %a@." label E.pp e;
  exit 1

let expect label = function
  | Ok v -> v
  | Error e -> fail_conn label e

let print_bools label xs =
  xs
  |> List.map string_of_bool
  |> String.concat ", "
  |> Printf.printf "%s: [%s]\n" label

let print_info label (info : B.info) =
  let expansion =
    match info.expansion with
    | None -> "n/a"
    | Some n -> string_of_int n
  in
  Printf.printf
    "%s: capacity=%d items=%d filters=%d error=%g expansion=%s\n"
    label info.capacity info.items info.filters info.error_rate expansion

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6381 ()
  in
  Fun.protect ~finally:(fun () -> C.close client) @@ fun () ->

  ignore (C.del client [ key; campaign_key; nonscaling_key ]);

  expect "BF.RESERVE"
    (B.reserve client ~key ~error_rate:0.01 ~capacity:1000);
  Printf.printf "ada newly added: %b\n"
    (expect "BF.ADD ada" (B.add client ~key "ada@example.com"));
  Printf.printf "ada duplicate add: %b\n"
    (expect "BF.ADD duplicate"
       (B.add client ~key "ada@example.com"));

  print_bools "bulk add"
    (expect "BF.MADD"
       (B.madd client ~key
          [ "grace@example.com";
            "ada@example.com";
            "katherine@example.com";
          ]));
  print_bools "bulk exists"
    (expect "BF.MEXISTS"
       (B.mexists client ~key
          [ "ada@example.com";
            "missing@example.com";
            "grace@example.com";
          ]));
  Printf.printf "approximate cardinality: %d\n"
    (expect "BF.CARD" (B.card client ~key));
  print_info "main filter" (expect "BF.INFO" (B.info client ~key));

  let campaign_options : B.insert_options =
    { B.default_insert_options with
      capacity = Some 200;
      error_rate = Some 0.001;
      scaling = B.Expansion 2;
    }
  in
  print_bools "campaign insert"
    (expect "BF.INSERT"
       (B.insert client ~options:campaign_options ~key:campaign_key
          ~items:[ "summer"; "winter"; "summer" ]));

  expect "BF.RESERVE non-scaling"
    (B.reserve client ~scaling:B.Non_scaling ~key:nonscaling_key
       ~error_rate:0.01 ~capacity:5);
  (match
     expect "BF.INFO EXPANSION"
       (B.info_value client ~key:nonscaling_key B.Expansion_rate)
   with
   | B.Not_applicable ->
       Printf.printf "non-scaling expansion: n/a\n"
   | B.Int n ->
       Printf.printf "non-scaling expansion: %d\n" n
   | B.Float f ->
       Printf.printf "non-scaling expansion: %g\n" f);

  ignore (C.del client [ key; campaign_key; nonscaling_key ])
