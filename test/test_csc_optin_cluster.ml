(** B2.5 cluster: OPTIN against a real cluster.

    Standalone OPTIN is covered by [test_csc_optin.ml]. This file
    exercises the cluster-specific paths: the [CLIENT CACHING YES
    + read] pair travels through {!Cluster_router}'s redirect-aware
    retry, so a slot-move between the two frames re-submits the
    whole pair on the new owner.

    Requires the docker-compose cluster
    ([docker compose -f docker-compose.cluster.yml up -d]). *)

module C = Valkey.Client
module Cfg = Valkey.Client.Config
module Cache = Valkey.Cache
module CC = Valkey.Client_cache
module CR = Valkey.Cluster_router
module Conn = Valkey.Connection
module E = Valkey.Connection.Error
module R = Valkey.Resp3

let seeds = [ "valkey-c1", 7000; "valkey-c2", 7001; "valkey-c3", 7002 ]
let grace_s = 0.05

let force_skip () =
  try Sys.getenv "VALKEY_CLUSTER" = "skip" with Not_found -> false

let cluster_reachable () =
  if force_skip () then false
  else
    try
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in
      let h, p = List.hd seeds in
      let conn =
        Conn.connect ~sw ~net ~clock ~config:Conn.Config.default
          ~host:h ~port:p ()
      in
      Conn.close conn;
      true
    with _ -> false

let skipped name =
  Printf.printf "    [SKIP] %s (cluster not reachable)\n" name

let sleep_ms env ms =
  Eio.Time.sleep (Eio.Stdenv.clock env) (ms /. 1000.0)

let with_optin_cluster ~keys f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let cache = Cache.create ~byte_budget:(1024 * 1024) in
  let ccfg = CC.make ~cache ~mode:CC.Optin () in
  let cluster_cfg =
    let d = CR.Config.default ~seeds in
    { d with connection =
               { d.connection with client_cache = Some ccfg } }
  in
  let router =
    match CR.create ~sw ~net ~clock ~config:cluster_cfg () with
    | Ok r -> r
    | Error e -> Alcotest.failf "cluster router: %s" e
  in
  let client =
    C.from_router
      ~config:{ Cfg.default with connection = cluster_cfg.connection }
      router
  in
  let aux_router =
    match CR.create ~sw ~net ~clock ~config:(CR.Config.default ~seeds) ()
    with
    | Ok r -> r
    | Error e -> Alcotest.failf "aux router: %s" e
  in
  let aux = C.from_router ~config:Cfg.default aux_router in
  let cleanup () = List.iter (fun k -> let _ = C.del aux [k] in ()) keys in
  cleanup ();
  let finally () = cleanup (); C.close client; C.close aux in
  Fun.protect ~finally (fun () -> f env client cache aux)

(* OPTIN cluster smoke: two keys in different shards (different
   hashtags), both get cached on first read, both get invalidated
   when an external SET fires from aux. The load-bearing
   property: each shard's connection sees its own
   [CLIENT CACHING YES + read] pair, the server registers tracking
   on each shard's primary, and per-shard invalidation pushes
   reach our shared [Cache.t] via the per-shard invalidator
   fibers. *)
let test_two_shards_populate_and_evict () =
  if not (cluster_reachable ()) then
    skipped "cluster: OPTIN populate + cross-shard evict"
  else
    let k_a = "{sharda}:ocaml:csc:optin:cluster:a" in
    let k_b = "{shardb}:ocaml:csc:optin:cluster:b" in
    with_optin_cluster ~keys:[k_a; k_b] @@ fun env client cache aux ->
    let _ = C.exec aux [| "SET"; k_a; "va" |] in
    let _ = C.exec aux [| "SET"; k_b; "vb" |] in
    (match C.get client k_a with
     | Ok (Some "va") -> ()
     | other ->
         Alcotest.failf "GET k_a: expected Some va, got %s"
           (match other with
            | Ok None -> "None"
            | Ok (Some s) -> Printf.sprintf "Some %S" s
            | Error e -> Format.asprintf "Error %a" E.pp e));
    (match C.get client k_b with
     | Ok (Some "vb") -> ()
     | other ->
         Alcotest.failf "GET k_b: expected Some vb, got %s"
           (match other with
            | Ok None -> "None"
            | Ok (Some s) -> Printf.sprintf "Some %S" s
            | Error e -> Format.asprintf "Error %a" E.pp e));
    Alcotest.(check int) "both shards' entries cached" 2
      (Cache.count cache);
    let _ = C.exec aux [| "SET"; k_a; "va2" |] in
    let _ = C.exec aux [| "SET"; k_b; "vb2" |] in
    sleep_ms env (grace_s *. 4.0 *. 1000.0);
    (* Both invalidations propagated; cache is empty until next
       read. If OPTIN's [CACHING YES + read] pair didn't actually
       arrive together on either shard's connection, that shard's
       primary wouldn't have registered tracking, no inv would
       arrive, and that shard's cached entry would stick. *)
    Alcotest.(check int) "both shard entries invalidated" 0
      (Cache.count cache)

(* Pair-on-cluster smoke: 25 fibers each issue an OPTIN GET on a
   distinct hashtag-anchored key spread across the 3 shards;
   external SETs on every key from aux must fire 25 invalidations.
   Detects any wire-adjacency break in the pair under concurrent
   per-shard enqueueing — a broken pair leaves at least one read
   untracked, no inv arrives for it, and that entry sticks. *)
let test_concurrent_optin_cluster () =
  if not (cluster_reachable ()) then
    skipped "cluster: OPTIN 25-fiber concurrent tracking"
  else
    let n = 25 in
    let keys =
      List.init n (fun i ->
        let tag =
          match i mod 3 with
          | 0 -> "sharda" | 1 -> "shardb" | _ -> "shardc"
        in
        Printf.sprintf "{%s}:ocaml:csc:optin:cluster:c:%d" tag i)
    in
    with_optin_cluster ~keys @@ fun env client cache aux ->
    List.iter (fun k -> let _ = C.exec aux [| "SET"; k; "v0" |] in ()) keys;
    Eio.Fiber.List.iter
      (fun k ->
        match C.get client k with
        | Ok (Some "v0") -> ()
        | other ->
            Alcotest.failf "concurrent OPTIN GET %S: %s" k
              (match other with
               | Ok None -> "None"
               | Ok (Some s) -> Printf.sprintf "Some %S" s
               | Error e -> Format.asprintf "Error %a" E.pp e))
      keys;
    Alcotest.(check int) "all keys cached" n (Cache.count cache);
    List.iter (fun k -> let _ = C.exec aux [| "SET"; k; "v1" |] in ()) keys;
    let drained =
      let clock = Eio.Stdenv.clock env in
      let deadline = Eio.Time.now clock +. 3.0 in
      let rec loop () =
        if Cache.count cache = 0 then true
        else if Eio.Time.now clock >= deadline then false
        else (sleep_ms env 20.0; loop ())
      in
      loop ()
    in
    if not drained then
      Alcotest.failf
        "expected all %d concurrent OPTIN entries to be \
         invalidated within 3s; %d still cached"
        n (Cache.count cache)

let tests =
  [ Alcotest.test_case "OPTIN cluster: two-shard populate + evict"
      `Quick test_two_shards_populate_and_evict;
    Alcotest.test_case "OPTIN cluster: 25-fiber concurrent tracking"
      `Quick test_concurrent_optin_cluster;
  ]
