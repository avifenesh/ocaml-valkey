(** RESP3 parser. Streamed aggregates raise [Parse_error] for now. *)

exception Parse_error of string

type byte_source = {
  any_char : unit -> char;
  line : unit -> string;
  take : int -> string;
}
(** Abstract byte producer. The parser is agnostic over the source: a plain
    [Eio.Buf_read.t] (see [of_buf_read]) or a cross-domain byte channel
    fed by a separate IO fiber. *)

val of_buf_read : Eio.Buf_read.t -> byte_source

val read : byte_source -> Resp3.t
