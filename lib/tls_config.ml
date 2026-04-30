let () = Mirage_crypto_rng_unix.use_default ()

type own_cert =
  [ `None | `Single of X509.Certificate.t list * X509.Private_key.t ]

type t = {
  authenticator : X509.Authenticator.t;
  server_name : [ `host ] Domain_name.t option;
  client_cert : own_cert;
}

let null_auth ?ip:_ ~host:_ _ = Ok None

let insecure () =
  { authenticator = null_auth; server_name = None; client_cert = `None }

let parse_host s =
  match Domain_name.of_string s with
  | Error _ -> None
  | Ok d -> (match Domain_name.host d with Ok h -> Some h | Error _ -> None)

let with_ca_cert ?server_name ~ca_pem () =
  let cas =
    match X509.Certificate.decode_pem_multiple ca_pem with
    | Ok certs -> certs
    | Error (`Msg m) -> invalid_arg ("Tls_config.with_ca_cert: " ^ m)
  in
  let auth = X509.Authenticator.chain_of_trust ~time:(fun () -> None) cas in
  let sn = Option.bind server_name parse_host in
  { authenticator = auth; server_name = sn; client_cert = `None }

let with_system_cas ?server_name () =
  match Ca_certs.authenticator () with
  | Error (`Msg m) -> Error m
  | Ok auth ->
      let sn = Option.bind server_name parse_host in
      Ok { authenticator = auth; server_name = sn; client_cert = `None }

(* Redact PEM-decode errors — X509's [`Msg _] sometimes includes
   byte offsets / partial cert data that we must not leak into
   user-facing errors. Keep only the failing step name. *)
let redact_pem_error ~step _ =
  Printf.sprintf "Tls_config.with_client_cert: %s decode failed" step

let with_client_cert ?server_name ~ca_pem ~client_cert_pem ~client_key_pem () =
  let ( let* ) r f = Result.bind r f in
  let* cas =
    match X509.Certificate.decode_pem_multiple ca_pem with
    | Ok [] ->
        Error "Tls_config.with_client_cert: ca_pem contained no certificates"
    | Ok certs -> Ok certs
    | Error m -> Error (redact_pem_error ~step:"ca_pem" m)
  in
  let* chain =
    match X509.Certificate.decode_pem_multiple client_cert_pem with
    | Ok [] ->
        Error "Tls_config.with_client_cert: \
               client_cert_pem contained no certificates"
    | Ok certs -> Ok certs
    | Error m -> Error (redact_pem_error ~step:"client_cert_pem" m)
  in
  let* key =
    match X509.Private_key.decode_pem client_key_pem with
    | Ok k -> Ok k
    | Error m -> Error (redact_pem_error ~step:"client_key_pem" m)
  in
  let auth = X509.Authenticator.chain_of_trust ~time:(fun () -> None) cas in
  let sn = Option.bind server_name parse_host in
  Ok { authenticator = auth;
       server_name = sn;
       client_cert = `Single (chain, key) }

let authenticator t = t.authenticator

let server_name t = t.server_name

let client_certificates t = t.client_cert
