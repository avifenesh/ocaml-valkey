(** Typed form of a Valkey server error reply. *)

type t = {
  code : string;
  message : string;
}

val of_string : string -> t

val to_string : t -> string

val equal : t -> t -> bool

val pp : Format.formatter -> t -> unit
