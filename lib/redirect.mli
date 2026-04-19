(** MOVED / ASK redirect parsing.

    Valkey returns an error of the form:
      -MOVED <slot> <host>:<port>
      -ASK   <slot> <host>:<port>

    [Valkey_error.of_string] already splits [code] (MOVED / ASK) from
    the rest. This module parses the rest. *)

type kind = Moved | Ask

type t = {
  kind : kind;
  slot : int;
  host : string;
  port : int;
}

val of_valkey_error : Valkey_error.t -> t option
(** Returns [Some t] iff the error code is MOVED or ASK and the
    message parses as [<slot> <host>:<port>]. *)
