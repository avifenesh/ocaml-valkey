(* Connection-level error variant. Lifted out of [Connection]
   so sibling modules ([Client_cache], [Invalidation]) can refer
   to the type without pulling in the whole [Connection] module
   (which would create a dependency cycle). [Connection.Error]
   re-exports this unchanged. *)

type t =
  | Tcp_refused of string
  | Dns_failed of string
  | Tls_failed of string
  | Handshake_rejected of Valkey_error.t
  | Auth_failed of Valkey_error.t
  | Protocol_violation of string
  | Timeout
  | Interrupted
  | Queue_full
  | Circuit_open
  | Closed
  | Server_error of Valkey_error.t
  | Terminal of string

let equal = ( = )

let pp ppf = function
  | Tcp_refused s -> Format.fprintf ppf "Tcp_refused(%s)" s
  | Dns_failed s -> Format.fprintf ppf "Dns_failed(%s)" s
  | Tls_failed s -> Format.fprintf ppf "Tls_failed(%s)" s
  | Handshake_rejected e ->
      Format.fprintf ppf "Handshake_rejected(%a)" Valkey_error.pp e
  | Auth_failed e -> Format.fprintf ppf "Auth_failed(%a)" Valkey_error.pp e
  | Protocol_violation s -> Format.fprintf ppf "Protocol_violation(%s)" s
  | Timeout -> Format.pp_print_string ppf "Timeout"
  | Interrupted -> Format.pp_print_string ppf "Interrupted"
  | Queue_full -> Format.pp_print_string ppf "Queue_full"
  | Circuit_open -> Format.pp_print_string ppf "Circuit_open"
  | Closed -> Format.pp_print_string ppf "Closed"
  | Server_error e -> Format.fprintf ppf "Server_error(%a)" Valkey_error.pp e
  | Terminal s -> Format.fprintf ppf "Terminal(%s)" s

let is_terminal = function
  | Auth_failed _ | Protocol_violation _ | Closed | Terminal _ -> true
  | Handshake_rejected _ | Tls_failed _ -> true
  | Tcp_refused _ | Dns_failed _ | Timeout | Interrupted | Queue_full
  | Circuit_open | Server_error _ -> false
