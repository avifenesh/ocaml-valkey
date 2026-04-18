type t = {
  code : string;
  message : string;
}

let of_string s =
  match String.index_opt s ' ' with
  | None -> { code = s; message = "" }
  | Some i ->
      let code = String.sub s 0 i in
      let message = String.sub s (i + 1) (String.length s - i - 1) in
      { code; message }

let to_string { code; message } =
  if message = "" then code else code ^ " " ^ message

let equal a b = a.code = b.code && a.message = b.message

let pp ppf { code; message } =
  if message = "" then Format.pp_print_string ppf code
  else Format.fprintf ppf "%s %s" code message
