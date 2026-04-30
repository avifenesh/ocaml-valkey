(** TLS configuration for a Valkey connection. *)

type t

val insecure : unit -> t
(** No certificate verification. Testing only. *)

val with_ca_cert : ?server_name:string -> ca_pem:string -> unit -> t
(** Verify server certificate against the given CA PEM content (not file
    path; caller reads the file). [server_name] supplies SNI and peer
    hostname verification. *)

val with_system_cas : ?server_name:string -> unit -> (t, string) result
(** Verify using the host's system CA bundle (via [ca-certs]). Use this for
    managed services like AWS ElastiCache / MemoryDB or any Valkey server
    with a cert signed by a public CA. Returns an error if the OS CA bundle
    cannot be located. *)

val with_client_cert :
  ?server_name:string ->
  ca_pem:string ->
  client_cert_pem:string ->
  client_key_pem:string ->
  unit ->
  (t, string) result
(** mTLS: server verified against [ca_pem], client presents
    [client_cert_pem] + [client_key_pem] to the server. PEM
    string contents (not file paths; the caller reads the
    files). Returns an error on decode failure; error messages
    are redacted and never include cert bytes.

    Use against self-managed Valkey clusters that require client
    certificate authentication. ElastiCache IAM users don't
    need this — the SigV4 auth token goes in the AUTH command
    instead. *)

(**/**)

(** Internal — used by [Connection] to construct the TLS client config. *)
val authenticator : t -> X509.Authenticator.t

val server_name : t -> [ `host ] Domain_name.t option

(** Internal — optional client certificate chain + key for mTLS. *)
val client_certificates :
  t ->
  [ `None | `Single of X509.Certificate.t list * X509.Private_key.t ]
