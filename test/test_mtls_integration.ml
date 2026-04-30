(** Live-server mTLS integration. Requires a Valkey with
    [tls-auth-clients yes] on :6391 (see docker-compose.mtls.yml).

    Gated by:
    - [MTLS=1] env var (explicit opt-in; not part of default CI).
    - Reachability probe (skip cleanly if :6391 isn't listening).

    Asserts:
    - A TLS handshake succeeds when a valid client cert + key from
      [tls/client.{crt,key}] (signed by [tls/ca.crt]) is presented.
    - The server rejects a handshake that presents no client cert
      at all; the typed error surfaces as [Tls_failed _] from
      [Connection.connect]. *)

module C = Valkey.Connection
module T = Valkey.Tls_config

let host = "localhost"
let port = 6391

let mtls_enabled () =
  try Sys.getenv "MTLS" = "1" with Not_found -> false

let mtls_server_reachable () =
  let ( let* ) = Result.bind in
  try
    let addr = Unix.(ADDR_INET (inet_addr_loopback, port)) in
    let s = Unix.socket PF_INET SOCK_STREAM 0 in
    let res =
      try Unix.connect s addr; Ok ()
      with _ -> Error "not reachable"
    in
    Unix.close s;
    let* () = res in
    Ok ()
  with _ -> Error "probe failed"

let skipped name =
  Alcotest.test_case name `Quick (fun () ->
    Printf.printf
      "(skipped: MTLS=1 + running docker-compose.mtls.yml required)%!")

let read_file path =
  let ic = open_in path in
  let len = in_channel_length ic in
  let buf = really_input_string ic len in
  close_in ic;
  buf

(* Resolve fixture paths the same way test_mtls_config does. *)
let fixture name =
  let candidates = [
    "../../tls/" ^ name;
    "../../../tls/" ^ name;
    "tls/" ^ name;
  ] in
  let rec try_ = function
    | [] ->
        Alcotest.failf
          "tls/%s not found (run [bash scripts/gen-tls-certs.sh])" name
    | p :: rest ->
        if Sys.file_exists p then read_file p else try_ rest
  in
  try_ candidates

(* Valid client cert: handshake must succeed and PING reply. *)
let test_mtls_handshake_with_valid_client_cert () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let tls =
    match
      T.with_client_cert
        ~server_name:"localhost"
        ~ca_pem:(fixture "ca.crt")
        ~client_cert_pem:(fixture "client.crt")
        ~client_key_pem:(fixture "client.key") ()
    with
    | Ok t -> t
    | Error m -> Alcotest.failf "with_client_cert: %s" m
  in
  let cfg = { C.Config.default with tls = Some tls } in
  let conn = C.connect ~sw ~net ~clock ~config:cfg ~host ~port () in
  Fun.protect ~finally:(fun () -> C.close conn) @@ fun () ->
  match C.request conn [| "PING" |] with
  | Ok (Simple_string "PONG") -> ()
  | Ok v ->
      Alcotest.failf "PING: unexpected %a"
        Valkey.Resp3.pp v
  | Error e ->
      Alcotest.failf "PING: %a" C.Error.pp e

(* No client cert (server-auth-only TLS) must be rejected by the
   server with Tls_failed. We use [with_ca_cert] which leaves
   [client_cert = `None], so tls-eio presents no client cert. *)
let test_mtls_rejects_connection_without_client_cert () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let tls =
    T.with_ca_cert ~server_name:"localhost" ~ca_pem:(fixture "ca.crt") ()
  in
  let cfg = { C.Config.default with tls = Some tls } in
  try
    let conn =
      C.connect ~sw ~net ~clock ~config:cfg ~host ~port ()
    in
    C.close conn;
    Alcotest.fail
      "expected handshake to fail without client cert; got Ok"
  with
  | C.Handshake_failed (C.Error.Tls_failed _) -> ()
  | C.Handshake_failed e ->
      Alcotest.failf "expected Tls_failed, got %a" C.Error.pp e

let tests =
  match mtls_enabled (), mtls_server_reachable () with
  | false, _ ->
      [ skipped "mTLS: valid client cert succeeds";
        skipped "mTLS: missing client cert rejected";
      ]
  | true, Error reason ->
      let msg =
        Printf.sprintf
          "mTLS server on :%d: %s (start via \
           [docker compose -f docker-compose.mtls.yml up -d])"
          port reason
      in
      [ skipped msg; skipped msg ]
  | true, Ok () ->
      [ Alcotest.test_case "mTLS: valid client cert succeeds"
          `Slow test_mtls_handshake_with_valid_client_cert;
        Alcotest.test_case "mTLS: missing client cert rejected"
          `Slow test_mtls_rejects_connection_without_client_cert;
      ]
