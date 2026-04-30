(* iam_smoke — manual proof-of-life against a real ElastiCache for
   Valkey cluster that requires IAM auth.

   Not CI-wired. Run locally by anyone with an AWS account and a
   configured ElastiCache user. Reads everything from env vars
   so the binary itself has no AWS-specific constants:

     AWS_ACCESS_KEY_ID          via Iam_credentials.of_env
     AWS_SECRET_ACCESS_KEY      via Iam_credentials.of_env
     AWS_SESSION_TOKEN          (optional, STS / IRSA case)
     AWS_REGION                 e.g. us-east-1
     ELASTICACHE_HOST           the primary / configuration endpoint
                                (e.g. my-cluster.abc.cache.amazonaws.com)
     ELASTICACHE_PORT           default 6379
     ELASTICACHE_CLUSTER_ID     the replication-group id or
                                serverless-cache name (lowercase)
     ELASTICACHE_USER_ID        the ElastiCache IAM user id (must
                                match user-name exactly)

   Optional tuning (defaults below):
     IAM_REFRESH_INTERVAL       seconds between token refreshes
                                (default 600 = 10 min)
     SMOKE_DURATION_SECONDS     total test runtime (default 900 =
                                15 min, long enough to cross one
                                token-refresh boundary)
     SMOKE_OPS_PER_SECOND       target SET rate (default 50)

   Exit codes:
     0 — test completed; every op succeeded, at least one token
         refresh observed in the run window.
     1 — configuration error (missing env var, bad TLS).
     2 — runtime error (failing op, provider error, reconnect
         storm). Check stderr. *)

let ( let* ) = Result.bind

let getenv_required name =
  match Sys.getenv_opt name with
  | Some "" | None ->
      Error (Printf.sprintf "env var %s is not set" name)
  | Some v -> Ok v

let getenv_int_opt name ~default =
  match Sys.getenv_opt name with
  | Some "" | None -> default
  | Some v ->
      (try int_of_string v
       with Failure _ ->
         Printf.eprintf
           "warning: %s=%S is not an int; using default %d\n%!"
           name v default;
         default)

let getenv_float_opt name ~default =
  match Sys.getenv_opt name with
  | Some "" | None -> default
  | Some v ->
      (try float_of_string v
       with Failure _ ->
         Printf.eprintf
           "warning: %s=%S is not a float; using default %f\n%!"
           name v default;
         default)

type config = {
  creds : Valkey.Iam_credentials.t;
  region : string;
  host : string;
  port : int;
  cluster_id : string;
  user_id : string;
  refresh_interval : float;
  duration_seconds : float;
  ops_per_second : int;
}

let load_config () =
  let* creds = Valkey.Iam_credentials.of_env () in
  let* region = getenv_required "AWS_REGION" in
  let* host = getenv_required "ELASTICACHE_HOST" in
  let port =
    getenv_int_opt "ELASTICACHE_PORT" ~default:6379
  in
  let* cluster_id = getenv_required "ELASTICACHE_CLUSTER_ID" in
  let* user_id = getenv_required "ELASTICACHE_USER_ID" in
  Ok {
    creds;
    region;
    host;
    port;
    cluster_id;
    user_id;
    refresh_interval =
      getenv_float_opt "IAM_REFRESH_INTERVAL" ~default:600.0;
    duration_seconds =
      getenv_float_opt "SMOKE_DURATION_SECONDS" ~default:900.0;
    ops_per_second =
      getenv_int_opt "SMOKE_OPS_PER_SECOND" ~default:50;
  }

let () =
  match load_config () with
  | Error msg ->
      Printf.eprintf "config error: %s\n" msg;
      exit 1
  | Ok cfg ->
      Eio_main.run @@ fun env ->
      Eio.Switch.run @@ fun sw ->
      let net = Eio.Stdenv.net env in
      let clock = Eio.Stdenv.clock env in

      (* ElastiCache requires TLS for IAM. Use system CAs — AWS
         endpoints are signed by a public CA. *)
      let tls =
        match
          Valkey.Tls_config.with_system_cas ~server_name:cfg.host ()
        with
        | Ok t -> t
        | Error m ->
            Printf.eprintf "tls config: %s\n" m;
            exit 1
      in

      let iam_cfg =
        let base =
          Valkey.Iam_provider.Config.default
            ~user_id:cfg.user_id
            ~cluster_id:cfg.cluster_id
            ~region:cfg.region
        in
        { base with refresh_interval = cfg.refresh_interval }
      in
      let iam =
        Valkey.Iam_provider.create
          ~sw ~clock ~credentials:cfg.creds ~config:iam_cfg
      in
      let initial_token =
        Valkey.Iam_provider.current_token iam
      in

      let client_cfg =
        { Valkey.Client.Config.default with
          connection =
            { Valkey.Connection.Config.default with
              tls = Some tls } }
      in
      let client =
        Valkey.Client.connect_with_iam
          ~sw ~net ~clock ~config:client_cfg ~iam
          ~host:cfg.host ~port:cfg.port ()
      in

      Printf.printf
        "iam_smoke: connected to %s:%d\n\
         iam_smoke: user=%s cluster=%s region=%s\n\
         iam_smoke: refresh every %.0fs, running %.0fs at %d ops/s\n%!"
        cfg.host cfg.port cfg.user_id cfg.cluster_id cfg.region
        cfg.refresh_interval cfg.duration_seconds cfg.ops_per_second;

      let start = Eio.Time.now clock in
      let deadline = start +. cfg.duration_seconds in
      let sleep_per_op = 1.0 /. float_of_int cfg.ops_per_second in
      let ops_ok = ref 0 in
      let ops_err = ref 0 in
      let token_rotations = ref 0 in
      let last_token = ref initial_token in
      let key = "iam_smoke:counter" in

      let rec loop i =
        if Eio.Time.now clock >= deadline then ()
        else begin
          let v = Printf.sprintf "v-%d" i in
          (match Valkey.Client.set client key v with
           | Ok _ -> incr ops_ok
           | Error e ->
               incr ops_err;
               Format.eprintf "SET %d: %a@." i
                 Valkey.Connection.Error.pp e);
          let cur = Valkey.Iam_provider.current_token iam in
          if cur <> !last_token then begin
            incr token_rotations;
            last_token := cur;
            Printf.printf
              "iam_smoke: token rotated (rotation #%d at t=%.0fs)\n%!"
              !token_rotations (Eio.Time.now clock -. start)
          end;
          (* Every 30 seconds, log progress. *)
          if i > 0 && (i mod (cfg.ops_per_second * 30)) = 0 then
            Printf.printf
              "iam_smoke: t=%.0fs, ok=%d, err=%d, rotations=%d\n%!"
              (Eio.Time.now clock -. start)
              !ops_ok !ops_err !token_rotations;
          Eio.Time.sleep clock sleep_per_op;
          loop (i + 1)
        end
      in
      loop 0;

      Printf.printf
        "\niam_smoke: summary\n\
         \telapsed:        %.0fs\n\
         \tops ok:         %d\n\
         \tops err:        %d\n\
         \ttoken rotations: %d\n%!"
        (Eio.Time.now clock -. start)
        !ops_ok !ops_err !token_rotations;

      Valkey.Client.close client;

      if !ops_err > 0 then begin
        Printf.eprintf "FAIL: %d ops errored\n" !ops_err;
        exit 2
      end;
      if !token_rotations < 1 && cfg.duration_seconds >= cfg.refresh_interval
      then begin
        Printf.eprintf
          "FAIL: ran for %.0fs (>= refresh interval %.0fs) but \
           observed zero rotations; refresh fiber stuck?\n"
          cfg.duration_seconds cfg.refresh_interval;
        exit 2
      end;
      Printf.printf "PASS\n"
