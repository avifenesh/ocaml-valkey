(** RESP3 command serialiser. *)

val write_command : Buffer.t -> string array -> unit

val command_to_string : string array -> string
