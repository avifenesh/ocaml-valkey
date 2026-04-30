(** Integration test for the IAM-shaped push-AUTH refresh loop.

    Simulates what [Iam_provider]'s refresh fiber does in
    production (re-sign token → push AUTH onto every live
    connection → close and reconnect on failure) using a local
    ACL user whose password we rotate out-of-band. This covers
    the real wire machinery — [Auth.custom], [Connection.refresh_auth],
    handshake-on-reconnect, recovery on bad AUTH — without
    needing an AWS account.

    Why this test exists: unit tests pin the SigV4 signer
    byte-exact against AWS vectors, and they prove [Iam_provider]
    rotates a cached string. But they don't prove the *combined*
    flow: provider → handshake → refresh fiber → live AUTH
    push → workload uninterrupted. This test does. *)

module C = Valkey.Connection
module Cl = Valkey.Client
module Auth = Valkey.Connection.Auth
module R = Valkey.Resp3

let host = "localhost"
let port = 6379

let test_push_auth_keeps_workload_alive_through_rotations () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let admin = C.connect ~sw ~net ~clock ~host ~port () in
  let user =
    Printf.sprintf "ocaml_valkey_refloop_%d" (Random.int 1_000_000)
  in
  let initial_pw = "pw_0" in
  Fun.protect
    ~finally:(fun () ->
      let _ = C.request admin [| "ACL"; "DELUSER"; user |] in
      C.close admin)
  @@ fun () ->
  (match
     C.request admin
       [| "ACL"; "SETUSER"; user; "ON";
          ">" ^ initial_pw; "+@all"; "~*"; "&*" |]
   with
   | Ok (R.Simple_string "OK") -> ()
   | Ok v -> Alcotest.failf "ACL SETUSER: %a" R.pp v
   | Error e -> Alcotest.failf "ACL SETUSER: %a" C.Error.pp e);

  (* Provider-shaped auth closure backed by a shared ref — same
     shape as [Iam_provider.auth_provider], same invariants. *)
  let current_pw = Atomic.make initial_pw in
  let provider =
    Auth.custom ~name:"iam" (fun () ->
      user, Atomic.get current_pw)
  in

  (* Open a conn against that provider. Handshake must pull the
     current password via the closure. *)
  let conn_cfg =
    { C.Config.default with
      handshake = { C.Handshake.default with auth = Some provider }
    }
  in
  let c = C.connect ~sw ~net ~clock ~config:conn_cfg ~host ~port () in
  Fun.protect ~finally:(fun () -> C.close c) @@ fun () ->
  (match C.request c [| "PING" |] with
   | Ok (R.Simple_string "PONG") -> ()
   | other ->
       Alcotest.failf "initial PING: %s"
         (match other with
          | Ok v -> Format.asprintf "Ok %a" R.pp v
          | Error e -> Format.asprintf "Error %a" C.Error.pp e));

  (* Workload fiber: hammer PING in the background while the
     refresher rotates the password underneath. *)
  let workload_ok = Atomic.make 0 in
  let workload_err = Atomic.make 0 in
  let stop = Atomic.make false in
  let workload () =
    while not (Atomic.get stop) do
      (match C.request c [| "PING" |] with
       | Ok (R.Simple_string "PONG") ->
           Atomic.incr workload_ok
       | Ok _ | Error _ ->
           Atomic.incr workload_err);
      Eio.Time.sleep clock 0.005
    done
  in

  (* Rotation fiber: rotate the password server-side, then push
     AUTH onto the live conn via [refresh_auth]. Five rotations
     over ~2 s. *)
  let rotations_ok = Atomic.make 0 in
  let rotate () =
    let n = 5 in
    for i = 1 to n do
      let new_pw = Printf.sprintf "pw_%d" i in
      (* Rotate on the server first. *)
      (match
         C.request admin
           [| "ACL"; "SETUSER"; user; "RESETPASS"; ">" ^ new_pw |]
       with
       | Ok (R.Simple_string "OK") -> ()
       | Ok v -> Alcotest.failf "ACL RESETPASS: %a" R.pp v
       | Error e -> Alcotest.failf "ACL RESETPASS: %a" C.Error.pp e);
      (* Then update the shared ref so the provider returns the
         new password on the next handshake. *)
      Atomic.set current_pw new_pw;
      (* Push in place via refresh_auth. *)
      (match C.refresh_auth c ~user ~password:new_pw with
       | Ok () -> Atomic.incr rotations_ok
       | Error e ->
           Alcotest.failf "refresh_auth rotation %d: %a"
             i C.Error.pp e);
      Eio.Time.sleep clock 0.4
    done
  in

  Eio.Fiber.both
    workload
    (fun () -> rotate (); Atomic.set stop true);

  (* Every rotation must have taken. *)
  Alcotest.(check int) "5 rotations landed" 5
    (Atomic.get rotations_ok);
  (* Workload survived: PINGs should be plentiful, errors zero.
     The auth refresh is in-place on the live socket, so the
     workload fiber never sees a disturbance. *)
  Alcotest.(check bool) "workload had many ok PINGs"
    true
    (Atomic.get workload_ok > 50);
  Alcotest.(check int) "workload saw zero errors during rotations"
    0 (Atomic.get workload_err)

(* Second case: refresh_auth with a password the server doesn't
   know → Auth_failed → supervisor reconnects with the provider's
   *current* (good) password → workload resumes. *)
let test_bad_refresh_forces_recovery_through_provider () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let admin = C.connect ~sw ~net ~clock ~host ~port () in
  let user =
    Printf.sprintf "ocaml_valkey_refloop_bad_%d" (Random.int 1_000_000)
  in
  let good_pw = "good" in
  Fun.protect
    ~finally:(fun () ->
      let _ = C.request admin [| "ACL"; "DELUSER"; user |] in
      C.close admin)
  @@ fun () ->
  (match
     C.request admin
       [| "ACL"; "SETUSER"; user; "ON";
          ">" ^ good_pw; "+@all"; "~*"; "&*" |]
   with
   | Ok (R.Simple_string "OK") -> ()
   | Ok v -> Alcotest.failf "ACL SETUSER: %a" R.pp v
   | Error e -> Alcotest.failf "ACL SETUSER: %a" C.Error.pp e);

  let current_pw = Atomic.make good_pw in
  let provider =
    Auth.custom ~name:"iam" (fun () ->
      user, Atomic.get current_pw)
  in
  let conn_cfg =
    { C.Config.default with
      handshake = { C.Handshake.default with auth = Some provider }
    }
  in
  let c = C.connect ~sw ~net ~clock ~config:conn_cfg ~host ~port () in
  Fun.protect ~finally:(fun () -> C.close c) @@ fun () ->
  (* Baseline. *)
  (match C.request c [| "PING" |] with
   | Ok (R.Simple_string "PONG") -> ()
   | other ->
       Alcotest.failf "initial PING: %s"
         (match other with
          | Ok v -> Format.asprintf "Ok %a" R.pp v
          | Error e -> Format.asprintf "Error %a" C.Error.pp e));

  (* Push refresh_auth with a password the server has NEVER seen.
     The provider ref still holds good_pw, so the subsequent
     reconnect handshake will use it — and succeed. *)
  (match C.refresh_auth c ~user ~password:"never-issued" with
   | Error (C.Error.Auth_failed _) -> ()
   | Ok () ->
       Alcotest.fail "refresh_auth with unknown pw should not Ok"
   | Error e ->
       Alcotest.failf "expected Auth_failed, got %a" C.Error.pp e);

  (* Supervisor reconnects using the provider (→ good_pw) and
     flips state back to Alive. *)
  let rec wait_alive deadline =
    match C.state c with
    | C.Alive -> ()
    | C.Dead e ->
        Alcotest.failf "unexpected Dead: %a" C.Error.pp e
    | _ ->
        if Eio.Time.now clock >= deadline then
          Alcotest.fail "supervisor did not bring conn back to Alive"
        else (Eio.Time.sleep clock 0.05; wait_alive deadline)
  in
  wait_alive (Eio.Time.now clock +. 3.0);
  (* Workload resumes on the recovered socket. *)
  (match C.request c [| "PING" |] with
   | Ok (R.Simple_string "PONG") -> ()
   | other ->
       Alcotest.failf "PING post-recovery: %s"
         (match other with
          | Ok v -> Format.asprintf "Ok %a" R.pp v
          | Error e -> Format.asprintf "Error %a" C.Error.pp e))

(* Third case: rotate the ACL password via admin, DON'T update
   the provider's ref. The live [refresh_auth] push will see
   Auth_failed → connection drops → supervisor reconnects using
   the provider's stale password → handshake fails with
   Auth_failed terminally. Proves the "stale provider" failure
   mode surfaces cleanly rather than looping forever. *)
let test_stale_provider_terminal_auth_failure () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let admin = C.connect ~sw ~net ~clock ~host ~port () in
  let user =
    Printf.sprintf "ocaml_valkey_refloop_stale_%d" (Random.int 1_000_000)
  in
  let initial = "initial-pw" in
  Fun.protect
    ~finally:(fun () ->
      let _ = C.request admin [| "ACL"; "DELUSER"; user |] in
      C.close admin)
  @@ fun () ->
  (match
     C.request admin
       [| "ACL"; "SETUSER"; user; "ON";
          ">" ^ initial; "+@all"; "~*"; "&*" |]
   with
   | Ok (R.Simple_string "OK") -> ()
   | Ok v -> Alcotest.failf "ACL SETUSER: %a" R.pp v
   | Error e -> Alcotest.failf "ACL SETUSER: %a" C.Error.pp e);

  let current_pw = Atomic.make initial in
  let provider =
    Auth.custom ~name:"iam" (fun () ->
      user, Atomic.get current_pw)
  in
  let conn_cfg =
    { C.Config.default with
      handshake = { C.Handshake.default with auth = Some provider };
      reconnect =
        { C.Reconnect.default with
          max_attempts = Some 2;
          initial_backoff = 0.05;
          max_backoff = 0.1;
          handshake_timeout = 1.0;
        }
    }
  in
  let c = C.connect ~sw ~net ~clock ~config:conn_cfg ~host ~port () in
  Fun.protect ~finally:(fun () -> C.close c) @@ fun () ->
  (match C.request c [| "PING" |] with
   | Ok (R.Simple_string "PONG") -> ()
   | other ->
       Alcotest.failf "initial PING: %s"
         (match other with
          | Ok v -> Format.asprintf "Ok %a" R.pp v
          | Error e -> Format.asprintf "Error %a" C.Error.pp e));

  (* Rotate server-side. Provider is now stale. *)
  (match
     C.request admin
       [| "ACL"; "SETUSER"; user; "RESETPASS"; ">" ^ "rotated-pw" |]
   with
   | Ok (R.Simple_string "OK") -> ()
   | Ok v -> Alcotest.failf "ACL rotate: %a" R.pp v
   | Error e -> Alcotest.failf "ACL rotate: %a" C.Error.pp e);

  (* refresh_auth with the stale password. Server rejects;
     connection drops; reconnect also fails (provider still
     stale). After max_attempts the conn goes Dead. *)
  (match C.refresh_auth c ~user ~password:initial with
   | Error (C.Error.Auth_failed _) -> ()
   | Ok () ->
       Alcotest.fail "refresh_auth with stale pw should not Ok"
   | Error e ->
       Alcotest.failf "expected Auth_failed, got %a" C.Error.pp e);

  (* Wait for terminal state. Reconnect attempts exhaust the
     budget because the provider keeps returning the stale
     password; the conn ends up Dead.

     We actively issue PINGs while waiting: the supervisor needs
     the dispatch pipeline to notice the broken socket so it can
     flip state. A pure passive sleep in the test fiber doesn't
     give the reader/parser fibers a reason to observe EOF. *)
  let rec wait_terminal deadline =
    match C.state c with
    | C.Dead _ -> ()
    | C.Alive ->
        (* Kick the conn — a failing request on a broken socket
           is what lets the supervisor see the disconnect. *)
        let _ = C.request ~timeout:0.1 c [| "PING" |] in
        if Eio.Time.now clock >= deadline then
          Alcotest.failf
            "conn stayed Alive — reconnect path accepted stale \
             password despite server RESETPASS"
        else (Eio.Time.sleep clock 0.05; wait_terminal deadline)
    | _ ->
        if Eio.Time.now clock >= deadline then
          Alcotest.fail "conn did not reach Dead within budget"
        else (Eio.Time.sleep clock 0.05; wait_terminal deadline)
  in
  wait_terminal (Eio.Time.now clock +. 5.0)

(* Router.all_connections round-trip. Opens a standalone client
   with connections_per_node > 1 and verifies the accessor
   returns the bundle, plus that an enumerator registered with
   a provider-style closure sees the same set. *)
let test_router_all_connections_standalone_bundle () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let n = 4 in
  let client_cfg =
    { Cl.Config.default with connections_per_node = n }
  in
  let client =
    Cl.connect ~sw ~net ~clock ~config:client_cfg ~host ~port ()
  in
  Fun.protect ~finally:(fun () -> Cl.close client) @@ fun () ->
  let router = Cl.For_testing.router client in
  let conns = Valkey.Router.all_connections router in
  Alcotest.(check int)
    "standalone router exposes the full bundle" n
    (List.length conns);
  (* Every conn should be Alive. *)
  List.iter
    (fun c ->
      match C.state c with
      | C.Alive -> ()
      | _ ->
          Alcotest.failf
            "expected all bundle conns to be Alive, got %s"
            (match C.state c with
             | C.Alive -> "Alive"
             | C.Connecting -> "Connecting"
             | C.Recovering -> "Recovering"
             | C.Dead e -> Format.asprintf "Dead(%a)" C.Error.pp e))
    conns;
  (* Round-trip: every one answers PING. *)
  List.iter
    (fun c ->
      match C.request c [| "PING" |] with
      | Ok (R.Simple_string "PONG") -> ()
      | other ->
          Alcotest.failf "bundle conn PING: %s"
            (match other with
             | Ok v -> Format.asprintf "Ok %a" R.pp v
             | Error e -> Format.asprintf "Error %a" C.Error.pp e))
    conns

(* Cluster variant: router-exposed all_connections returns every
   node × connections_per_node conn, so an IAM provider's
   enumerator wired to [Router.all_connections] covers the
   whole fleet at refresh tick. *)
let cluster_reachable () = Test_support.cluster_reachable ()

let seeds = Test_support.seeds

let test_router_all_connections_cluster () =
  if not (cluster_reachable ()) then
    Test_support.skipped "cluster: Router.all_connections"
  else
    Eio_main.run @@ fun env ->
    Eio.Switch.run @@ fun sw ->
    let net = Eio.Stdenv.net env in
    let clock = Eio.Stdenv.clock env in
    let per_node = 2 in
    let cluster_cfg =
      let d = Valkey.Cluster_router.Config.default ~seeds in
      { d with connections_per_node = per_node }
    in
    let router =
      match
        Valkey.Cluster_router.create
          ~sw ~net ~clock ~config:cluster_cfg ()
      with
      | Ok r -> r
      | Error e -> Alcotest.failf "cluster_router: %s" e
    in
    let client =
      Cl.from_router ~sw ~net ~clock
        ~config:Cl.Config.default router
    in
    Fun.protect ~finally:(fun () -> Cl.close client) @@ fun () ->
    let conns = Valkey.Router.all_connections router in
    (* 3 primaries × 2 per_node = 6 (replicas are not in the
       live pool unless Read_from requests them — see
       Node_pool semantics). Accept >= primaries × per_node as
       a lower bound, but pin upper bound too so we catch
       accidental over-enumeration. *)
    let expected_primaries = 3 in
    let min_expected = expected_primaries * per_node in
    Alcotest.(check bool)
      "at least primaries × per_node conns visible"
      true (List.length conns >= min_expected);
    (* All should be Alive (router is freshly built). *)
    List.iter
      (fun c ->
        match C.state c with
        | C.Alive -> ()
        | _ ->
            Alcotest.failf
              "unexpected non-Alive conn in cluster bundle: %s"
              (match C.state c with
               | C.Alive -> "Alive"
               | C.Connecting -> "Connecting"
               | C.Recovering -> "Recovering"
               | C.Dead e -> Format.asprintf "Dead(%a)" C.Error.pp e))
      conns;
    (* Sanity: every conn answers PING. *)
    List.iter
      (fun c ->
        match C.request c [| "PING" |] with
        | Ok _ -> ()
        | Error e ->
            Alcotest.failf "cluster bundle PING: %a" C.Error.pp e)
      conns

let tests =
  [ Alcotest.test_case
      "push_auth keeps workload alive through 5 rotations"
      `Slow test_push_auth_keeps_workload_alive_through_rotations;
    Alcotest.test_case
      "bad refresh_auth recovers via provider's good password"
      `Slow test_bad_refresh_forces_recovery_through_provider;
    Alcotest.test_case
      "stale provider produces terminal Auth_failed"
      `Slow test_stale_provider_terminal_auth_failure;
    Alcotest.test_case
      "Router.all_connections returns standalone bundle"
      `Quick test_router_all_connections_standalone_bundle;
    Alcotest.test_case
      "Router.all_connections across cluster bundle"
      `Slow test_router_all_connections_cluster;
  ]
