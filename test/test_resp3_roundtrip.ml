(** ∀ v, parse (encode v) = v.

    Randomised round-trip check. Hand-rolled generator (no qcheck
    dependency — keeps the test suite self-contained, matches the
    style of [bin/fuzz_parser/]).

    Seed is fixed so failures are reproducible; bump [iterations]
    to smoke out long-tail bugs locally. *)

module R = Valkey.Resp3
module P = Valkey.Resp3_parser

let iterations = 10_000
let seed = 0xB001 (* fixed; reproducible *)

let crlf = "\r\n"

(* ---------- encoder (server→client direction).

   Kept in sync with the one in [bin/fuzz_parser/fuzz_parser.ml].
   If the two drift this test or the fuzzer will surface it. *)
let rec encode (v : R.t) =
  match v with
  | R.Simple_string s -> "+" ^ s ^ crlf
  | R.Simple_error s  -> "-" ^ s ^ crlf
  | R.Integer n       -> ":" ^ Int64.to_string n ^ crlf
  | R.Null            -> "_" ^ crlf
  | R.Boolean b       -> "#" ^ (if b then "t" else "f") ^ crlf
  | R.Double f ->
      let body =
        if Float.is_nan f then "nan"
        else if f = Float.infinity then "inf"
        else if f = Float.neg_infinity then "-inf"
        else if Float.is_integer f && Float.abs f <= 1e15 then
          Printf.sprintf "%.0f" f
        else Printf.sprintf "%.17g" f
      in
      "," ^ body ^ crlf
  | R.Big_number s -> "(" ^ s ^ crlf
  | R.Bulk_string s ->
      "$" ^ string_of_int (String.length s) ^ crlf ^ s ^ crlf
  | R.Bulk_error s ->
      "!" ^ string_of_int (String.length s) ^ crlf ^ s ^ crlf
  | R.Verbatim_string { encoding; data } ->
      let body = encoding ^ ":" ^ data in
      "=" ^ string_of_int (String.length body) ^ crlf ^ body ^ crlf
  | R.Array xs ->
      "*" ^ string_of_int (List.length xs) ^ crlf
      ^ String.concat "" (List.map encode xs)
  | R.Set xs ->
      "~" ^ string_of_int (List.length xs) ^ crlf
      ^ String.concat "" (List.map encode xs)
  | R.Push xs ->
      ">" ^ string_of_int (List.length xs) ^ crlf
      ^ String.concat "" (List.map encode xs)
  | R.Map kvs ->
      "%" ^ string_of_int (List.length kvs) ^ crlf
      ^ String.concat ""
          (List.map (fun (k, v) -> encode k ^ encode v) kvs)

let parse s = P.read (P.of_buf_read (Eio.Buf_read.of_string s))

(* ---------- generator ---------- *)

(* Simple-string / Simple-error bodies: no CR, no LF. ASCII printable. *)
let gen_simple_line rng =
  let n = Random.State.int rng 32 in
  String.init n (fun _ ->
      let c = 32 + Random.State.int rng 95 in
      Char.chr c)

(* Bulk payloads: any bytes, including CRLF. *)
let gen_bulk_payload rng max_size =
  let n = Random.State.int rng (max_size + 1) in
  String.init n (fun _ -> Char.chr (Random.State.int rng 256))

(* Big-number: -?[0-9]+. *)
let gen_big_number rng =
  let sign = if Random.State.bool rng then "-" else "" in
  let digits =
    String.init
      (1 + Random.State.int rng 30)
      (fun _ -> Char.chr (Char.code '0' + Random.State.int rng 10))
  in
  sign ^ digits

(* Verbatim encoding: 3 lowercase letters (txt/mkd/...). *)
let gen_verbatim_encoding rng =
  String.init 3 (fun _ ->
      Char.chr (Char.code 'a' + Random.State.int rng 26))

(* Doubles: we generate a mix of integers, finite fractions, and
   infinities. NaN is excluded from the random generator (tested
   as a one-off below) because structural equality on NaN is false
   and would make the round-trip property vacuously fail. *)
let gen_double rng =
  match Random.State.int rng 10 with
  | 0 -> Float.infinity
  | 1 -> Float.neg_infinity
  | 2 -> 0.0
  | 3 -> Float.of_int (Random.State.int rng 1_000_000 - 500_000)
  | 4 ->
      Float.of_int (Random.State.int rng 1_000_000 - 500_000) /. 100.0
  | _ -> Random.State.float rng 1e9 -. 5e8

let rec gen_value rng ~depth ~max_depth ~max_payload =
  let pick_leaf () =
    match Random.State.int rng 10 with
    | 0 -> R.Null
    | 1 -> R.Boolean (Random.State.bool rng)
    | 2 ->
        R.Integer
          (Int64.of_int (Random.State.int rng 1_000_000 - 500_000))
    | 3 -> R.Simple_string (gen_simple_line rng)
    | 4 -> R.Simple_error (gen_simple_line rng)
    | 5 -> R.Double (gen_double rng)
    | 6 -> R.Big_number (gen_big_number rng)
    | 7 -> R.Bulk_string (gen_bulk_payload rng max_payload)
    | 8 -> R.Bulk_error (gen_simple_line rng)
    | _ ->
        R.Verbatim_string
          { encoding = gen_verbatim_encoding rng;
            data = gen_bulk_payload rng max_payload }
  in
  if depth >= max_depth then pick_leaf ()
  else
    match Random.State.int rng 14 with
    | 10 ->
        let n = Random.State.int rng 5 in
        R.Array
          (List.init n (fun _ ->
               gen_value rng ~depth:(depth + 1) ~max_depth ~max_payload))
    | 11 ->
        let n = Random.State.int rng 5 in
        R.Set
          (List.init n (fun _ ->
               gen_value rng ~depth:(depth + 1) ~max_depth ~max_payload))
    | 12 ->
        let n = Random.State.int rng 5 in
        R.Push
          (List.init n (fun _ ->
               gen_value rng ~depth:(depth + 1) ~max_depth ~max_payload))
    | 13 ->
        let n = Random.State.int rng 5 in
        R.Map
          (List.init n (fun _ ->
               ( gen_value rng ~depth:(depth + 1) ~max_depth ~max_payload,
                 gen_value rng ~depth:(depth + 1) ~max_depth ~max_payload )))
    | _ -> pick_leaf ()

(* ---------- assertions ---------- *)

(* R.equal uses polymorphic equality, which does the right thing for
   every constructor we round-trip here — including Double, since the
   encoder emits a lossless representation for finite values and
   [inf]/[-inf] are structurally equal to themselves. NaN is the one
   exception; see [test_double_nan]. *)
let resp3 = Alcotest.testable R.pp R.equal

let round_trip v =
  let wire = encode v in
  let parsed =
    try parse wire
    with exn ->
      Alcotest.failf
        "parse raised %s on encoded value %a (wire=%S)"
        (Printexc.to_string exn) R.pp v wire
  in
  Alcotest.check resp3 "round-trip" v parsed

(* ---------- leaf-only sweep ---------- *)

let test_round_trip_leaves () =
  let rng = Random.State.make [| seed |] in
  for _ = 1 to iterations do
    let v = gen_value rng ~depth:0 ~max_depth:0 ~max_payload:128 in
    round_trip v
  done

(* ---------- nested sweep ---------- *)

let test_round_trip_nested () =
  let rng = Random.State.make [| seed + 1 |] in
  for _ = 1 to iterations do
    let v =
      gen_value rng ~depth:0 ~max_depth:4 ~max_payload:64
    in
    round_trip v
  done

(* ---------- targeted edge cases ---------- *)

let test_empty_aggregates () =
  round_trip (R.Array []);
  round_trip (R.Set []);
  round_trip (R.Push []);
  round_trip (R.Map []);
  round_trip (R.Bulk_string "");
  round_trip (R.Verbatim_string { encoding = "txt"; data = "" })

let test_bulk_with_crlf () =
  round_trip (R.Bulk_string "a\r\nb\r\nc");
  round_trip (R.Bulk_string "\r\n\r\n");
  round_trip (R.Bulk_string "\000\001\002")

let test_int64_extremes () =
  round_trip (R.Integer Int64.max_int);
  round_trip (R.Integer Int64.min_int);
  round_trip (R.Integer 0L);
  round_trip (R.Integer (-1L))

let test_double_special () =
  round_trip (R.Double Float.infinity);
  round_trip (R.Double Float.neg_infinity);
  round_trip (R.Double 0.0);
  (* -0.0 is structurally equal to 0.0 under (=); encoder emits "-0"
     which parser reads back as 0.0. Skip. *)
  round_trip (R.Double 1.0);
  round_trip (R.Double (-1.5));
  round_trip (R.Double 1e15);
  round_trip (R.Double 1.23456789012345e-10)

(* NaN: (=) is false on NaN, so we check the parsed value is *also*
   a NaN rather than checking structural equality. *)
let test_double_nan () =
  match parse (encode (R.Double Float.nan)) with
  | R.Double f when Float.is_nan f -> ()
  | other ->
      Alcotest.failf
        "NaN round-trip produced %a" R.pp other

(* Pathological keys/values in maps: Bulk keys with binary data,
   Simple-string keys with spaces, nested Array keys. *)
let test_map_exotic_keys () =
  round_trip
    (R.Map
       [ R.Bulk_string "\000bin\r\nkey", R.Integer 1L;
         R.Simple_string "spaced key", R.Null;
         R.Array [ R.Integer 1L; R.Integer 2L ],
         R.Boolean true
       ])

let tests =
  [ Alcotest.test_case "leaves × 10k" `Quick test_round_trip_leaves;
    Alcotest.test_case "nested × 10k" `Quick test_round_trip_nested;
    Alcotest.test_case "empty aggregates" `Quick test_empty_aggregates;
    Alcotest.test_case "bulk with CRLF" `Quick test_bulk_with_crlf;
    Alcotest.test_case "int64 extremes" `Quick test_int64_extremes;
    Alcotest.test_case "double special" `Quick test_double_special;
    Alcotest.test_case "double NaN" `Quick test_double_nan;
    Alcotest.test_case "map exotic keys" `Quick test_map_exotic_keys;
  ]
