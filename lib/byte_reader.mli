(** Buffered reader over a stream of [Cstruct.t] chunks.

    Produces a [Resp3_parser.byte_source] so the parser can run on any
    domain, fed by an IO-domain fiber that pushes socket chunks. *)

type t

val create : ?initial_size:int -> Cstruct.t Eio.Stream.t -> t

val close : t -> unit
(** Signal EOF. After close, reads that need more bytes raise
    [End_of_stream]. *)

val to_byte_source : t -> Resp3_parser.byte_source

exception End_of_stream
