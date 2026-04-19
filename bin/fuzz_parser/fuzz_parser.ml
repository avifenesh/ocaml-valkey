(* RESP3 parser fuzzer.

   Feeds the parser a mix of random bytes, valid RESP3 encodings,
   and corrupted valid encodings. For each input, expects one of:

     - Ok _                          parsed to a Resp3.t
     - Parse_error  _                rejected cleanly
     - End_of_stream                 ran out of bytes cleanly

   Anything else — arbitrary exceptions, segfaults, infinite loops,
   memory blowups — is a bug. The fuzzer categorises outcomes and
   exits non-zero if any "unexpected" outcomes show up.

   Distinct from [bin/fuzz/] (which is a client-level stability
   soak against a live server). *)

module P = Valkey.Resp3_parser
module R = Valkey.Resp3

(* ---------- CLI ---------- *)

type args = {
  iterations : int;
  seed : int option;
  max_input_bytes : int;
  max_depth : int;
  strict : bool;       (* exit 1 if any "unexpected" seen *)
}

let default_args = {
  iterations = 50_000;
  seed = None;
  max_input_bytes = 16 * 1024;
  max_depth = 6;
  strict = false;
}

let parse_args () =
  let a = ref default_args in
  let specs =
    [ "--iterations", Arg.Int (fun n -> a := { !a with iterations = n }),
      "N number of fuzz inputs (default 50000)";
      "--seed", Arg.Int (fun n -> a := { !a with seed = Some n }),
      "N seed the RNG for reproducibility";
      "--max-bytes", Arg.Int (fun n -> a := { !a with max_input_bytes = n }),
      "N upper bound on generated input size (default 16384)";
      "--max-depth", Arg.Int (fun n -> a := { !a with max_depth = n }),
      "N max nesting depth when generating valid trees (default 6)";
      "--strict", Arg.Unit (fun () -> a := { !a with strict = true }),
      " exit 1 if any unexpected outcomes occurred";
    ]
  in
  Arg.parse specs (fun _ -> ()) "valkey-fuzz-parser [OPTIONS]";
  !a

(* ---------- byte source from a string ---------- *)

exception Eos

let string_source (s : string) : P.byte_source =
  let pos = ref 0 in
  let need_available n =
    if !pos + n > String.length s then raise Eos
  in
  let any_char () =
    need_available 1;
    let c = s.[!pos] in
    incr pos;
    c
  in
  let line () =
    let rec scan i =
      if i + 1 >= String.length s then raise Eos
      else if s.[i] = '\r' && s.[i + 1] = '\n' then i
      else scan (i + 1)
    in
    let end_ = scan !pos in
    let r = String.sub s !pos (end_ - !pos) in
    pos := end_ + 2;
    r
  in
  let take n =
    need_available n;
    let r = String.sub s !pos n in
    pos := !pos + n;
    r
  in
  { any_char; line; take }

(* ---------- encoder for valid RESP3 trees ---------- *)

let crlf = "\r\n"

let rec encode (v : R.t) =
  match v with
  | R.Simple_string s -> "+" ^ s ^ crlf
  | R.Simple_error s -> "-" ^ s ^ crlf
  | R.Integer n -> ":" ^ Int64.to_string n ^ crlf
  | R.Null -> "_" ^ crlf
  | R.Boolean b -> "#" ^ (if b then "t" else "f") ^ crlf
  | R.Double f ->
      let body =
        if Float.is_nan f then "nan"
        else if Float.is_integer f
               && Float.abs f <= 1e15 then
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

(* ---------- generator ---------- *)

let gen_simple_line rng =
  let n = Random.State.int rng 32 in
  String.init n (fun _ ->
      let c = 32 + Random.State.int rng 95 in
      Char.chr c)

let gen_bulk_payload rng max_size =
  let n = Random.State.int rng (max_size + 1) in
  String.init n (fun _ -> Char.chr (Random.State.int rng 256))

let rec gen_value rng ~depth ~max_depth ~max_payload =
  let pick_leaf () =
    match Random.State.int rng 10 with
    | 0 -> R.Null
    | 1 -> R.Boolean (Random.State.bool rng)
    | 2 -> R.Integer (Int64.of_int (Random.State.int rng 1_000_000 - 500_000))
    | 3 -> R.Simple_string (gen_simple_line rng)
    | 4 -> R.Simple_error (gen_simple_line rng)
    | 5 -> R.Double
             (if Random.State.bool rng then
                float_of_int (Random.State.int rng 10000) /. 100.0
              else Random.State.float rng 1e9)
    | 6 -> R.Big_number
             (String.init (1 + Random.State.int rng 20)
                (fun i ->
                  if i = 0 && Random.State.bool rng then '-'
                  else Char.chr (Char.code '0' + Random.State.int rng 10)))
    | 7 -> R.Bulk_string (gen_bulk_payload rng max_payload)
    | 8 -> R.Bulk_error (gen_simple_line rng)
    | _ ->
        R.Verbatim_string
          { encoding = "txt";
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
               ( gen_value rng ~depth:(depth + 1) ~max_depth
                   ~max_payload,
                 gen_value rng ~depth:(depth + 1) ~max_depth
                   ~max_payload )))
    | _ -> pick_leaf ()

(* ---------- corruption ---------- *)

let corrupt rng s =
  let n = String.length s in
  if n = 0 then s
  else
    let b = Bytes.of_string s in
    let n_ops = 1 + Random.State.int rng 5 in
    for _ = 1 to n_ops do
      match Random.State.int rng 4 with
      | 0 ->
          (* flip a random byte *)
          let i = Random.State.int rng (Bytes.length b) in
          Bytes.set b i (Char.chr (Random.State.int rng 256))
      | 1 ->
          (* drop a byte *)
          let len = Bytes.length b in
          if len > 0 then
            let i = Random.State.int rng len in
            let b2 = Bytes.create (len - 1) in
            Bytes.blit b 0 b2 0 i;
            Bytes.blit b (i + 1) b2 i (len - 1 - i);
            Bytes.blit b2 0 b 0 (len - 1);
            Bytes.set b (len - 1) '\x00'  (* b is same length; no-op
                                              terminator *)
      | 2 ->
          (* duplicate a byte *)
          let i = Random.State.int rng (Bytes.length b) in
          Bytes.set b i (Bytes.get b i)
      | _ ->
          (* zero a run *)
          let i = Random.State.int rng (Bytes.length b) in
          let len = min (1 + Random.State.int rng 4)
                      (Bytes.length b - i) in
          Bytes.fill b i len '\x00'
    done;
    Bytes.to_string b

(* Hand-crafted tricky inputs — the cheap-to-write seeds that catch
   the obvious edge cases. *)
let seed_inputs () =
  let bad_lengths = [
    "$-1\r\n";            (* RESP2 nil-bulk, rejected by RESP3 parser *)
    "$999999999\r\n";     (* claim much more than provided *)
    "$5\r\nhi\r\n";       (* length-mismatch *)
    "*-1\r\n";
    "*5\r\n:1\r\n";       (* array with fewer elems than claimed *)
    ":9223372036854775808\r\n";  (* int64 overflow *)
    ",\r\n";              (* empty double *)
    "#?\r\n";             (* invalid bool *)
    "$0\r\n\r\n";         (* empty bulk *)
    "*0\r\n";             (* empty array *)
    "~0\r\n";             (* empty set *)
    "%0\r\n";             (* empty map *)
    ">0\r\n";             (* empty push *)
    "";                   (* empty buffer *)
    "+OK";                (* no crlf *)
    "+OK\r";              (* partial crlf *)
    "$3\r\nAB";           (* truncated payload *)
    ":abc\r\n";           (* non-numeric int *)
    "$3\r\n\x00\x01\x02\r\n";   (* bulk with null bytes *)
  ] in
  bad_lengths

(* ---------- categorise one parse attempt ---------- *)

type outcome =
  | Ok_
  | Parse_err
  | Eof
  | Unexpected of string  (* exception name *)

let exn_name e =
  let s = Printexc.to_string e in
  try
    let sp = String.index s ' ' in
    String.sub s 0 sp
  with Not_found -> s

let run_once input =
  let src = string_source input in
  try
    let _ = P.read src in
    Ok_
  with
  | P.Parse_error _ -> Parse_err
  | Eos -> Eof
  | e -> Unexpected (exn_name e)

(* ---------- driver ---------- *)

type stats = {
  mutable ok : int;
  mutable parse_err : int;
  mutable eof : int;
  mutable unexpected_total : int;
  by_exn : (string, int) Hashtbl.t;
  mutable max_bytes_seen : int;
  mutable worst : (string * string) option;  (* (exn_name, first 80 bytes) *)
}

let make_stats () = {
  ok = 0; parse_err = 0; eof = 0; unexpected_total = 0;
  by_exn = Hashtbl.create 16;
  max_bytes_seen = 0;
  worst = None;
}

let record stats input outcome =
  stats.max_bytes_seen <- max stats.max_bytes_seen (String.length input);
  match outcome with
  | Ok_ -> stats.ok <- stats.ok + 1
  | Parse_err -> stats.parse_err <- stats.parse_err + 1
  | Eof -> stats.eof <- stats.eof + 1
  | Unexpected name ->
      stats.unexpected_total <- stats.unexpected_total + 1;
      (match Hashtbl.find_opt stats.by_exn name with
       | Some c -> Hashtbl.replace stats.by_exn name (c + 1)
       | None -> Hashtbl.replace stats.by_exn name 1);
      let snippet =
        String.escaped
          (if String.length input > 80 then String.sub input 0 80
           else input)
      in
      if stats.worst = None then stats.worst <- Some (name, snippet)

let ( % ) x y = if y = 0 then 0.0 else 100.0 *. float x /. float y

let print_report stats ~iterations ~elapsed =
  let total = stats.ok + stats.parse_err + stats.eof
              + stats.unexpected_total in
  Printf.printf "\n===== fuzz_parser report =====\n";
  Printf.printf "iterations      : %d\n" iterations;
  Printf.printf "inputs parsed   : %d\n" total;
  Printf.printf "elapsed         : %.2fs  (%.0f inputs/s)\n"
    elapsed
    (if elapsed > 0.0 then float_of_int total /. elapsed else 0.0);
  Printf.printf "max input size  : %d bytes\n" stats.max_bytes_seen;
  Printf.printf "\n-- outcomes --\n";
  Printf.printf "  ok (parsed)           %-8d  (%.1f%%)\n"
    stats.ok (stats.ok % total);
  Printf.printf "  Parse_error           %-8d  (%.1f%%)\n"
    stats.parse_err (stats.parse_err % total);
  Printf.printf "  End_of_stream         %-8d  (%.1f%%)\n"
    stats.eof (stats.eof % total);
  Printf.printf "  UNEXPECTED            %-8d  (%.1f%%)\n"
    stats.unexpected_total
    (stats.unexpected_total % total);
  if stats.unexpected_total > 0 then begin
    Printf.printf "\n-- unexpected exceptions by type --\n";
    Hashtbl.iter
      (fun name count -> Printf.printf "  %-30s %d\n" name count)
      stats.by_exn;
    (match stats.worst with
     | Some (name, snip) ->
         Printf.printf "\n  first hit: %s on input %S\n" name snip
     | None -> ())
  end;
  print_newline ()

let () =
  let args = parse_args () in
  let rng =
    match args.seed with
    | Some s -> Random.State.make [| s |]
    | None ->
        Random.self_init ();
        Random.State.make_self_init ()
  in

  let stats = make_stats () in
  let t_start = Unix.gettimeofday () in

  (* 1. seed inputs *)
  List.iter
    (fun s -> record stats s (run_once s))
    (seed_inputs ());

  (* 2. generated inputs *)
  for _ = 1 to args.iterations do
    let input =
      match Random.State.int rng 4 with
      | 0 ->
          (* Pure random bytes. *)
          let n = Random.State.int rng args.max_input_bytes in
          String.init n (fun _ -> Char.chr (Random.State.int rng 256))
      | 1 ->
          (* Valid encoded RESP3 value. *)
          let v =
            gen_value rng ~depth:0
              ~max_depth:args.max_depth
              ~max_payload:(min 2048 (args.max_input_bytes / 4))
          in
          encode v
      | 2 ->
          (* Valid encoding with a few random corruptions. *)
          let v =
            gen_value rng ~depth:0
              ~max_depth:args.max_depth
              ~max_payload:(min 2048 (args.max_input_bytes / 4))
          in
          corrupt rng (encode v)
      | _ ->
          (* Deliberately-truncated valid encoding: take a random
             prefix of a valid value's encoding. *)
          let v =
            gen_value rng ~depth:0
              ~max_depth:args.max_depth
              ~max_payload:(min 2048 (args.max_input_bytes / 4))
          in
          let s = encode v in
          if String.length s = 0 then s
          else
            String.sub s 0 (Random.State.int rng (String.length s))
    in
    record stats input (run_once input)
  done;

  let elapsed = Unix.gettimeofday () -. t_start in
  print_report stats ~iterations:args.iterations ~elapsed;

  if args.strict && stats.unexpected_total > 0 then begin
    Printf.eprintf
      "FAIL: %d unexpected exceptions (parser should only raise \
       Parse_error or propagate byte-source exhaustion)\n%!"
      stats.unexpected_total;
    exit 1
  end
