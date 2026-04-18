(** RESP3 wire value.

    Attributes ([|]) and streamed aggregates are handled by the parser,
    not represented as variants. *)

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

val equal : t -> t -> bool

val pp : Format.formatter -> t -> unit
