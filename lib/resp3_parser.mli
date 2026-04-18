(** RESP3 parser. Streamed aggregates raise [Parse_error] for now. *)

exception Parse_error of string

val read : Eio.Buf_read.t -> Resp3.t
