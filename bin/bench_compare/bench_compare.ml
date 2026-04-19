(* bench_compare — diff two bench JSON files, emit markdown.

   Reads two files produced by [bin/bench/] --json, matches scenarios
   by name, and prints a GitHub-flavoured markdown table of deltas.

   Usage:
     valkey-bench-compare BEFORE.json AFTER.json [--regress-threshold PCT]

   Exits 1 if any scenario's ops_per_sec dropped by more than
   --regress-threshold percent (default 10). Used by bench.yml to
   gate PRs on benchmark regressions. *)

(* ---------- minimal JSON reader (zero deps).

   The bench output is a flat structure with a single [scenarios]
   array of objects with known string/number fields. Parsing doesn't
   need to be robust to arbitrary JSON — just to what bench.ml
   produces. *)

type value =
  | V_str of string
  | V_num of float

type scenario_result = {
  name : string;
  count : int;
  ops_per_sec : float;
  avg_ms : float;
  p50_ms : float;
  p90_ms : float;
  p99_ms : float;
  p999_ms : float;
  max_ms : float;
}

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

(* Small hand-rolled JSON decoder tuned for our bench output shape.
   Supports strings, numbers, objects with string keys, arrays of
   objects. Escape handling is limited to what bench.ml emits. *)

let parse_json (src : string) : (string * value) list list =
  (* Returns the list of scenarios, each as an assoc list. *)
  let n = String.length src in
  let pos = ref 0 in
  let err msg = failwith (Printf.sprintf "json at %d: %s" !pos msg) in
  let skip_ws () =
    while !pos < n
          && (let c = src.[!pos] in
              c = ' ' || c = '\n' || c = '\r' || c = '\t' || c = ',')
    do incr pos done
  in
  let expect c =
    skip_ws ();
    if !pos >= n || src.[!pos] <> c then err (Printf.sprintf "expected %c" c);
    incr pos
  in
  let read_string () =
    expect '"';
    let b = Buffer.create 16 in
    while !pos < n && src.[!pos] <> '"' do
      if src.[!pos] = '\\' && !pos + 1 < n then begin
        (match src.[!pos + 1] with
         | 'n' -> Buffer.add_char b '\n'
         | 't' -> Buffer.add_char b '\t'
         | 'r' -> Buffer.add_char b '\r'
         | '"' -> Buffer.add_char b '"'
         | '\\' -> Buffer.add_char b '\\'
         | c -> Buffer.add_char b c);
        pos := !pos + 2
      end else begin
        Buffer.add_char b src.[!pos];
        incr pos
      end
    done;
    expect '"';
    Buffer.contents b
  in
  let read_number () =
    let start = !pos in
    while !pos < n
          && (let c = src.[!pos] in
              (c >= '0' && c <= '9') || c = '-' || c = '+'
              || c = '.' || c = 'e' || c = 'E')
    do incr pos done;
    let s = String.sub src start (!pos - start) in
    try float_of_string s
    with _ -> err (Printf.sprintf "bad number %S" s)
  in
  let rec read_value () =
    skip_ws ();
    if !pos >= n then err "unexpected eof";
    match src.[!pos] with
    | '"' -> V_str (read_string ())
    | _ -> V_num (read_number ())
  and read_object () =
    expect '{';
    let fields = ref [] in
    let loop = ref true in
    while !loop do
      skip_ws ();
      if !pos < n && src.[!pos] = '}' then begin incr pos; loop := false end
      else begin
        let k = read_string () in
        skip_ws ();
        expect ':';
        let v = read_value () in
        fields := (k, v) :: !fields
      end
    done;
    List.rev !fields
  and read_array () =
    expect '[';
    let items = ref [] in
    let loop = ref true in
    while !loop do
      skip_ws ();
      if !pos < n && src.[!pos] = ']' then begin incr pos; loop := false end
      else items := read_object () :: !items
    done;
    List.rev !items
  in
  (* Root is { "scenarios": [ ... ] }. *)
  skip_ws ();
  expect '{';
  skip_ws ();
  let _k = read_string () in
  skip_ws ();
  expect ':';
  read_array ()

let field_num fields k =
  match List.assoc_opt k fields with
  | Some (V_num n) -> n
  | _ -> failwith (Printf.sprintf "field %S missing or not a number" k)

let field_str fields k =
  match List.assoc_opt k fields with
  | Some (V_str s) -> s
  | _ -> failwith (Printf.sprintf "field %S missing or not a string" k)

let scenario_of_fields fields = {
  name = field_str fields "name";
  count = int_of_float (field_num fields "count");
  ops_per_sec = field_num fields "ops_per_sec";
  avg_ms = field_num fields "avg_ms";
  p50_ms = field_num fields "p50_ms";
  p90_ms = field_num fields "p90_ms";
  p99_ms = field_num fields "p99_ms";
  p999_ms = field_num fields "p999_ms";
  max_ms = field_num fields "max_ms";
}

let load path =
  parse_json (read_file path)
  |> List.map scenario_of_fields

(* ---------- diff + render ---------- *)

let pct_change before after =
  if before = 0.0 then 0.0
  else 100.0 *. (after -. before) /. before

let find_by_name xs name =
  List.find_opt (fun s -> s.name = name) xs

let render before after =
  let buf = Buffer.create 2048 in
  Buffer.add_string buf
    "| scenario | ops/s before | ops/s after | Δ ops/s | \
     p99 before | p99 after | Δ p99 |\n";
  Buffer.add_string buf
    "|---|---:|---:|---:|---:|---:|---:|\n";
  List.iter
    (fun a ->
      match find_by_name before a.name with
      | None ->
          Buffer.add_string buf
            (Printf.sprintf "| %s | _new_ | %.0f | — | _new_ | %.3fms | — |\n"
               a.name a.ops_per_sec a.p99_ms)
      | Some b ->
          let dops = pct_change b.ops_per_sec a.ops_per_sec in
          let dp99 = pct_change b.p99_ms a.p99_ms in
          let arrow_ops = if dops >= 0.0 then "+" else "" in
          let arrow_p99 = if dp99 >= 0.0 then "+" else "" in
          Buffer.add_string buf
            (Printf.sprintf
               "| %s | %.0f | %.0f | %s%.1f%% | %.3fms | %.3fms | %s%.1f%% |\n"
               a.name b.ops_per_sec a.ops_per_sec arrow_ops dops
               b.p99_ms a.p99_ms arrow_p99 dp99))
    after;
  Buffer.contents buf

let regressions ~threshold before after =
  List.filter_map
    (fun a ->
      match find_by_name before a.name with
      | None -> None
      | Some b ->
          let dops = pct_change b.ops_per_sec a.ops_per_sec in
          if dops < -. threshold then
            Some (a.name, b.ops_per_sec, a.ops_per_sec, dops)
          else None)
    after

let () =
  let threshold = ref 10.0 in
  let before = ref None in
  let after = ref None in
  let positional s =
    match !before, !after with
    | None, _ -> before := Some s
    | Some _, None -> after := Some s
    | _ -> ()
  in
  let specs =
    [ "--regress-threshold", Arg.Float (fun x -> threshold := x),
      "PCT fail if ops/s dropped by more than PCT% (default 10)" ]
  in
  Arg.parse specs positional
    "valkey-bench-compare BEFORE.json AFTER.json";
  match !before, !after with
  | Some b, Some a ->
      let before_r = load b in
      let after_r = load a in
      print_string (render before_r after_r);
      let regs = regressions ~threshold:!threshold before_r after_r in
      if regs <> [] then begin
        prerr_endline "\nREGRESSIONS:";
        List.iter
          (fun (n, bv, av, d) ->
            Printf.eprintf "  %s: %.0f -> %.0f (%.1f%%)\n" n bv av d)
          regs;
        exit 1
      end
  | _ ->
      prerr_endline "usage: valkey-bench-compare BEFORE.json AFTER.json";
      exit 2
