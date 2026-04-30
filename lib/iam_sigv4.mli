(** AWS Signature Version 4 signer for ElastiCache IAM tokens.

    The token is a presigned GET request URL to
    [http://<cache-id>/?Action=connect&User=<user-id>] signed
    with the caller's AWS credentials. The server accepts the
    full URL (minus the [http://] scheme) as the password in
    an [AUTH <user> <token>] command.

    Tokens are valid for 900 seconds (15 minutes). The
    ElastiCache server tolerates ±5 minutes of clock skew.
    Callers should refresh at least every 10 minutes; see
    [Iam_provider] for an automatic refresh fiber.

    This module is a bottom-up, pure-OCaml SigV4 implementation
    — no AWS SDK dependency. It uses {!Digestif.SHA256} for
    HMAC and hashing, which is already an opam dependency.
    Verified byte-exact against AWS's published test vectors
    (see [test/test_iam_sigv4.ml]). *)

val presigned_elasticache_token :
  credentials:Iam_credentials.t ->
  region:string ->
  cluster_id:string ->
  user_id:string ->
  now:float ->
  string
(** Returns the ElastiCache IAM token — the presigned URL
    minus the [http://] scheme prefix, ready to be used as the
    password in [HELLO ... AUTH user_id token] or
    [AUTH user_id token].

    [cluster_id] is the replication-group ID (serverless cache
    name or cluster-mode ID), lowercased as ElastiCache does.

    [now] is the Unix timestamp to embed as [X-Amz-Date]; pass
    [Eio.Time.now clock] or [Unix.gettimeofday ()]. The token
    expires [now + 900] seconds in AWS time. *)

(** {1 Internal primitives exposed for unit testing}

    These are the individual building blocks of the SigV4
    algorithm. They are documented in the AWS SigV4 spec and
    pinned against the official test vectors; stable surface
    for regression checking only. *)

val hex_sha256 : string -> string
(** Lower-case hex of SHA-256. *)

val hmac_sha256 : key:string -> string -> string
(** Raw HMAC-SHA256 (binary output). *)

val derive_signing_key :
  secret_access_key:string ->
  date:string ->
  region:string ->
  service:string ->
  string
(** Four-step HMAC derivation per SigV4:
    [kSecret = "AWS4" ^ secret]
    [kDate = HMAC(kSecret, date)]
    [kRegion = HMAC(kDate, region)]
    [kService = HMAC(kRegion, service)]
    [kSigning = HMAC(kService, "aws4_request")]

    [date] is the [YYYYMMDD] date stamp in UTC. *)

val percent_encode : reserved:bool -> string -> string
(** RFC 3986 unreserved-character percent-encoding. When
    [reserved = false], the encoded output preserves the
    unreserved set [A-Za-z0-9-._~]; everything else is
    [%HH]-encoded. When [reserved = true], additionally
    preserves [/] (used when encoding the canonical URI path,
    not values). *)

val canonical_query_string :
  (string * string) list -> string
(** Build the canonical query string: sort param pairs
    lexicographically by encoded key (then by encoded value),
    percent-encode both, join with [&].

    Used for both the presigned URL's query portion AND the
    canonical request's second line (they are identical
    by construction for presigned GETs). *)

type presign_steps = {
  canonical_query : string;
  canonical_request : string;
  string_to_sign : string;
  signature : string;
  token : string;
}

val presigned_elasticache_token_with_steps :
  credentials:Iam_credentials.t ->
  region:string ->
  cluster_id:string ->
  user_id:string ->
  now:float ->
  presign_steps
(** Same as {!presigned_elasticache_token} but also exposes the
    intermediate SigV4 stages, for pinning against AWS-published
    test vectors. *)
