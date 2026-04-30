(** AWS credentials used to sign ElastiCache IAM connect tokens.

    Minimal surface: the three fields that SigV4 needs. No
    provider-chain / IMDS / STS integration in v1 — users load
    credentials from wherever their deployment prefers
    (env vars, ECS task metadata, Vault, Kubernetes IRSA) and
    wrap the result in {!make}. *)

type t = {
  access_key_id : string;
  secret_access_key : string;
  session_token : string option;
    (** Present when the credentials come from STS / IAM role
        assumption. When [Some], SigV4 adds an
        [X-Amz-Security-Token] query parameter. *)
}

val make :
  access_key_id:string ->
  secret_access_key:string ->
  ?session_token:string ->
  unit -> t

val of_env : unit -> (t, string) result
(** Reads [AWS_ACCESS_KEY_ID], [AWS_SECRET_ACCESS_KEY], and
    (optional) [AWS_SESSION_TOKEN] from the process environment.
    Returns [Error] listing which required variable is missing. *)
