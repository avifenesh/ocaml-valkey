module R = Eio.Buf_read

exception Parse_error of string

let err fmt = Format.kasprintf (fun s -> raise (Parse_error s)) fmt

let expect_crlf r =
  let b = R.take 2 r in
  if b <> "\r\n" then err "expected CRLF, got %S" b

let parse_int64 s =
  try Int64.of_string s with _ -> err "invalid integer %S" s

let parse_int s =
  try int_of_string s with _ -> err "invalid integer %S" s

let parse_double s =
  match s with
  | "inf" | "+inf" -> Float.infinity
  | "-inf" -> Float.neg_infinity
  | "nan" -> Float.nan
  | _ -> (try float_of_string s with _ -> err "invalid double %S" s)

let read_bulk_body r =
  let len_s = R.line r in
  if len_s = "-1" then None
  else if len_s = "?" then err "streamed bulk strings not yet implemented"
  else
    let len = parse_int len_s in
    let body = R.take len r in
    expect_crlf r;
    Some body

let read_count r =
  let s = R.line r in
  if s = "-1" then `Null
  else if s = "?" then `Streamed
  else `Count (parse_int s)

let rec read (r : R.t) : Resp3.t =
  match R.any_char r with
  | '+' -> Simple_string (R.line r)
  | '-' -> Simple_error (R.line r)
  | ':' -> Integer (parse_int64 (R.line r))
  | '$' ->
      (match read_bulk_body r with
       | None -> Null
       | Some s -> Bulk_string s)
  | '*' ->
      (match read_count r with
       | `Null -> Null
       | `Streamed -> err "streamed arrays not yet implemented"
       | `Count n -> Array (read_n r n))
  | '_' ->
      let s = R.line r in
      if s <> "" then err "null with unexpected body %S" s;
      Null
  | '#' ->
      (match R.line r with
       | "t" -> Boolean true
       | "f" -> Boolean false
       | s -> err "invalid boolean %S" s)
  | ',' -> Double (parse_double (R.line r))
  | '(' -> Big_number (R.line r)
  | '!' ->
      (match read_bulk_body r with
       | None -> err "null bulk-error is not defined by the protocol"
       | Some s -> Bulk_error s)
  | '=' ->
      (match read_bulk_body r with
       | None -> err "null verbatim-string is not defined by the protocol"
       | Some s ->
           if String.length s < 4 || s.[3] <> ':' then
             err "malformed verbatim string %S" s;
           let encoding = String.sub s 0 3 in
           let data = String.sub s 4 (String.length s - 4) in
           Verbatim_string { encoding; data })
  | '%' ->
      (match read_count r with
       | `Null -> Null
       | `Streamed -> err "streamed maps not yet implemented"
       | `Count n -> Map (read_kvs r n))
  | '~' ->
      (match read_count r with
       | `Null -> Null
       | `Streamed -> err "streamed sets not yet implemented"
       | `Count n -> Set (read_n r n))
  | '>' ->
      (match read_count r with
       | `Null -> Null
       | `Streamed -> err "streamed pushes not yet implemented"
       | `Count n -> Push (read_n r n))
  | '|' ->
      (match read_count r with
       | `Null -> read r
       | `Streamed -> err "streamed attributes not yet implemented"
       | `Count n -> let _ = read_kvs r n in read r)
  | c -> err "unexpected RESP3 prefix %C" c

and read_n r n =
  let rec loop i acc = if i = 0 then List.rev acc else loop (i - 1) (read r :: acc) in
  loop n []

and read_kvs r n =
  let rec loop i acc =
    if i = 0 then List.rev acc
    else let k = read r in let v = read r in loop (i - 1) ((k, v) :: acc)
  in
  loop n []
