(* Cluster + TLS against a managed-service-style endpoint.

   Two patterns shown:

   1. Managed service (ElastiCache, MemoryDB, hosted Valkey) — uses
      the system CA bundle. Just point at the cluster endpoint
      with TLS enabled.

   2. Self-signed dev cluster — uses a custom CA. Reads a PEM file
      and passes it in. (Use scripts/gen-tls-certs.sh to make one.)

   This program won't actually connect anywhere by default — it's
   set up to be a template you copy. Set the host / port / CA path
   to your environment and rerun. *)

module C = Valkey.Client
module CR = Valkey.Cluster_router
module Conn = Valkey.Connection
module TLS = Valkey.Tls_config

(* Pattern 1: Managed Valkey / ElastiCache. *)
let _connect_managed ~sw ~net ~clock ~host ~port =
  let tls =
    match TLS.with_system_cas ~server_name:host () with
    | Ok t -> t
    | Error e -> failwith ("system CA bundle: " ^ e)
  in
  let connection_config =
    { Conn.Config.default with tls = Some tls }
  in
  let cfg =
    { (CR.Config.default ~seeds:[ host, port ]) with
      connection = connection_config;
      prefer_hostname = true }
  in
  match CR.create ~sw ~net ~clock ~config:cfg () with
  | Ok router -> C.from_router ~config:C.Config.default router
  | Error msg -> failwith ("cluster_router: " ^ msg)

(* Pattern 2: Self-signed cluster (dev / staging). *)
let _connect_self_signed ~sw ~net ~clock ~seeds ~ca_pem_path
    ~server_name =
  let ca_pem =
    let ic = open_in ca_pem_path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    s
  in
  let tls = TLS.with_ca_cert ~server_name ~ca_pem () in
  let connection_config =
    { Conn.Config.default with tls = Some tls }
  in
  let cfg =
    { (CR.Config.default ~seeds) with
      connection = connection_config;
      prefer_hostname = true }
  in
  match CR.create ~sw ~net ~clock ~config:cfg () with
  | Ok router -> C.from_router ~config:C.Config.default router
  | Error msg -> failwith ("cluster_router: " ^ msg)

let () =
  print_endline
    "tls.ml is a template. Edit one of:";
  print_endline
    "  - _connect_managed   for ElastiCache / hosted Valkey";
  print_endline
    "  - _connect_self_signed for an internal CA"
