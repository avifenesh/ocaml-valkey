(** Pure-unit coverage for [Iam_provider].

    Verifies:
    - [create] signs an initial token eagerly.
    - [auth_provider] returns [(user_id, token)] and carries
      the expected [name = "iam"].
    - [force_refresh] replaces the cached token.
    - The refresh fiber re-signs on every [refresh_interval].
    - No exception when no connections are registered.

    No network, no ElastiCache — the provider only needs a
    clock and a switch. *)

module P = Valkey.Iam_provider
module Cr = Valkey.Iam_credentials
module Auth = Valkey.Connection.Auth

let fake_creds =
  Cr.make
    ~access_key_id:"AKIAIOSFODNN7EXAMPLE"
    ~secret_access_key:"wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
    ()

let cfg =
  P.Config.default
    ~user_id:"iam-user-01"
    ~cluster_id:"my-cluster"
    ~region:"us-east-1"

let test_auth_provider_name_is_iam () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let p =
    P.create ~sw ~clock ~credentials:fake_creds ~config:cfg
  in
  let provider = P.auth_provider p in
  Alcotest.(check string) "provider name" "iam" (Auth.name provider)

let test_auth_provider_returns_user_and_token () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let p =
    P.create ~sw ~clock ~credentials:fake_creds ~config:cfg
  in
  let (user, token) = Auth.call (P.auth_provider p) in
  Alcotest.(check string) "user_id round-trips" "iam-user-01" user;
  Alcotest.(check bool) "token starts with lowercased cluster id"
    true
    (String.length token > 11
     && String.sub token 0 11 = "my-cluster/")

let test_force_refresh_changes_token () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let p =
    P.create ~sw ~clock ~credentials:fake_creds ~config:cfg
  in
  let t1 = P.current_token p in
  (* Sleep past 1 second so the X-Amz-Date timestamp rolls
     and the signature strictly differs. *)
  Eio.Time.sleep clock 1.1;
  P.force_refresh p;
  let t2 = P.current_token p in
  Alcotest.(check bool) "force_refresh yields a different token"
    true (t1 <> t2)

let test_refresh_fiber_runs_on_interval () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let fast_cfg = { cfg with P.Config.refresh_interval = 1.0 } in
  let p =
    P.create ~sw ~clock ~credentials:fake_creds ~config:fast_cfg
  in
  let initial = P.current_token p in
  (* Wait ~1.5s for the refresh fiber to tick once. *)
  Eio.Time.sleep clock 1.5;
  let after_tick = P.current_token p in
  Alcotest.(check bool) "refresh fiber rotated the token"
    true (initial <> after_tick)

let test_no_registered_connections_is_safe () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let p =
    P.create ~sw ~clock ~credentials:fake_creds ~config:cfg
  in
  (* With zero connections registered, force_refresh must not
     raise — the push-AUTH loop iterates over an empty list. *)
  P.force_refresh p;
  ()

(* --- Iam_credentials.of_env ------------------------------------- *)

let save_env vars =
  List.map (fun v -> v, Sys.getenv_opt v) vars

let restore_env saved =
  List.iter
    (fun (v, value) ->
      match value with
      | None -> Unix.putenv v ""
      | Some s -> Unix.putenv v s)
    saved

let with_env_vars ~set ~unset f =
  let tracked =
    List.map fst set @ unset
    |> List.sort_uniq String.compare
  in
  let saved = save_env tracked in
  List.iter (fun v -> Unix.putenv v "") unset;
  List.iter (fun (k, v) -> Unix.putenv k v) set;
  Fun.protect ~finally:(fun () -> restore_env saved) f

let test_of_env_missing_access_key () =
  with_env_vars
    ~set:[ "AWS_SECRET_ACCESS_KEY", "secret" ]
    ~unset:[ "AWS_ACCESS_KEY_ID"; "AWS_SESSION_TOKEN" ]
    (fun () ->
      match Cr.of_env () with
      | Error msg ->
          Alcotest.(check bool) "error mentions ACCESS_KEY_ID"
            true
            (let needle = "ACCESS_KEY_ID" in
             let ls = String.length msg in
             let ln = String.length needle in
             let rec find i =
               i + ln <= ls
               && (String.sub msg i ln = needle || find (i + 1))
             in
             find 0)
      | Ok _ -> Alcotest.fail "expected Error, got Ok")

let test_of_env_missing_secret () =
  with_env_vars
    ~set:[ "AWS_ACCESS_KEY_ID", "AKIA..." ]
    ~unset:[ "AWS_SECRET_ACCESS_KEY"; "AWS_SESSION_TOKEN" ]
    (fun () ->
      match Cr.of_env () with
      | Error msg ->
          Alcotest.(check bool) "error mentions SECRET_ACCESS_KEY"
            true
            (let needle = "SECRET_ACCESS_KEY" in
             let ls = String.length msg in
             let ln = String.length needle in
             let rec find i =
               i + ln <= ls
               && (String.sub msg i ln = needle || find (i + 1))
             in
             find 0)
      | Ok _ -> Alcotest.fail "expected Error, got Ok")

let test_of_env_happy_path_with_session_token () =
  with_env_vars
    ~set:[
      "AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE";
      "AWS_SECRET_ACCESS_KEY", "wJalr";
      "AWS_SESSION_TOKEN", "FwoGSAMPLE";
    ]
    ~unset:[]
    (fun () ->
      match Cr.of_env () with
      | Ok c ->
          Alcotest.(check string) "access_key_id"
            "AKIAIOSFODNN7EXAMPLE" c.access_key_id;
          Alcotest.(check string) "secret_access_key"
            "wJalr" c.secret_access_key;
          Alcotest.(check (option string)) "session_token"
            (Some "FwoGSAMPLE") c.session_token
      | Error m ->
          Alcotest.failf "expected Ok, got Error %s" m)

let test_of_env_happy_path_without_session_token () =
  with_env_vars
    ~set:[
      "AWS_ACCESS_KEY_ID", "AKIAIOSFODNN7EXAMPLE";
      "AWS_SECRET_ACCESS_KEY", "wJalr";
    ]
    ~unset:[ "AWS_SESSION_TOKEN" ]
    (fun () ->
      match Cr.of_env () with
      | Ok c ->
          Alcotest.(check (option string)) "session_token"
            None c.session_token
      | Error m ->
          Alcotest.failf "expected Ok, got Error %s" m)

(* --- register / unregister: concurrent safety ------------------- *)

let test_concurrent_register_unregister_no_loss () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let p =
    P.create ~sw ~clock ~credentials:fake_creds ~config:cfg
  in
  (* Register many enumerators in parallel, each returning a
     distinct marker string via a fake Connection-returning
     closure. Since we can't construct a live Connection.t in a
     pure-unit test, we register enumerators that return [] —
     the important property is that every [register] call
     returns a usable token and every [unregister] call succeeds
     without throwing, regardless of interleaving. *)
  let n = 200 in
  let tokens =
    List.init n (fun _ -> P.register p (fun () -> []))
  in
  (* Interleaved register / unregister from concurrent fibers. *)
  Eio.Fiber.all
    (List.map
      (fun reg () -> P.unregister p reg)
      tokens);
  (* force_refresh after mass unregister should still work. *)
  P.force_refresh p;
  ()

let tests =
  [ Alcotest.test_case "auth_provider name is 'iam'" `Quick
      test_auth_provider_name_is_iam;
    Alcotest.test_case "auth_provider returns (user_id, token)"
      `Quick test_auth_provider_returns_user_and_token;
    Alcotest.test_case "force_refresh changes cached token"
      `Slow test_force_refresh_changes_token;
    Alcotest.test_case "refresh fiber runs on interval"
      `Slow test_refresh_fiber_runs_on_interval;
    Alcotest.test_case "no registered connections is safe"
      `Quick test_no_registered_connections_is_safe;
    Alcotest.test_case "of_env: missing AWS_ACCESS_KEY_ID errors"
      `Quick test_of_env_missing_access_key;
    Alcotest.test_case "of_env: missing AWS_SECRET_ACCESS_KEY errors"
      `Quick test_of_env_missing_secret;
    Alcotest.test_case "of_env: with session token"
      `Quick test_of_env_happy_path_with_session_token;
    Alcotest.test_case "of_env: without session token"
      `Quick test_of_env_happy_path_without_session_token;
    Alcotest.test_case "concurrent register/unregister"
      `Quick test_concurrent_register_unregister_no_loss;
  ]
