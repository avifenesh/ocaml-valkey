type t =
  | Simple_string of string
  | Simple_error of string
  | Integer of int64
  | Bulk_string of string
  | Array of t list
  | Null
  | Boolean of bool
  | Double of float
  | Big_number of string
  | Bulk_error of string
  | Verbatim_string of { encoding : string; data : string }
  | Map of (t * t) list
  | Set of t list
  | Push of t list

let equal = ( = )

let rec pp ppf (v : t) =
  match v with
  | Simple_string s -> Format.fprintf ppf "+%s" s
  | Simple_error s  -> Format.fprintf ppf "-%s" s
  | Integer i       -> Format.fprintf ppf ":%Ld" i
  | Bulk_string s   -> Format.fprintf ppf "$%S" s
  | Array xs        -> Format.fprintf ppf "@[*[%a]@]" pp_items xs
  | Null            -> Format.pp_print_string ppf "_"
  | Boolean b       -> Format.fprintf ppf "#%s" (if b then "t" else "f")
  | Double f        -> Format.fprintf ppf ",%g" f
  | Big_number s    -> Format.fprintf ppf "(%s" s
  | Bulk_error s    -> Format.fprintf ppf "!%s" s
  | Verbatim_string { encoding; data } ->
      Format.fprintf ppf "=%s:%S" encoding data
  | Map kvs         -> Format.fprintf ppf "@[%%{%a}@]" pp_kvs kvs
  | Set xs          -> Format.fprintf ppf "@[~{%a}@]" pp_items xs
  | Push xs         -> Format.fprintf ppf "@[>[%a]@]" pp_items xs

and pp_items ppf xs =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.fprintf ppf ",@ ")
    pp ppf xs

and pp_kvs ppf kvs =
  Format.pp_print_list
    ~pp_sep:(fun ppf () -> Format.fprintf ppf ",@ ")
    (fun ppf (k, v) -> Format.fprintf ppf "%a => %a" pp k pp v)
    ppf kvs
