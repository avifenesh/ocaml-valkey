module Config = struct
  type t = {
    refresh_interval : float;
    user_id : string;
    cluster_id : string;
    region : string;
  }

  let default ~user_id ~cluster_id ~region =
    { refresh_interval = 600.0; user_id; cluster_id; region }
end

(* A [registration] wraps a caller-supplied enumerator closure.
   Physical-identity is used for unregister lookup, so the
   record has no other fields — the closure is the payload. *)
type registration = {
  enumerate : unit -> Connection.t list;
}

type t = {
  credentials : Iam_credentials.t;
  config : Config.t;
  clock : float Eio.Time.clock_ty Eio.Resource.t;
  cached_token : string Atomic.t;
  registrations : registration list Atomic.t;
}

let sign_now t =
  Iam_sigv4.presigned_elasticache_token
    ~credentials:t.credentials
    ~region:t.config.region
    ~cluster_id:t.config.cluster_id
    ~user_id:t.config.user_id
    ~now:(Eio.Time.now t.clock)

let current_token t = Atomic.get t.cached_token

(* Collect connections from every registered enumerator, skip
   [Dead _] entries. Duplicates (same Connection.t returned by
   more than one enumerator) are removed via [List.memq] so we
   don't send redundant AUTH commands. Enumeration is typically
   tens of connections at most, so an O(n²) dedup is fine. *)
let collect_live_connections t =
  let regs = Atomic.get t.registrations in
  List.fold_left
    (fun acc r ->
      let enum =
        try r.enumerate () with _ -> []
      in
      List.fold_left
        (fun acc conn ->
          match Connection.state conn with
          | Connection.Dead _ -> acc
          | _ when List.memq conn acc -> acc
          | _ -> conn :: acc)
        acc enum)
    [] regs

let push_auth_to_all t token =
  let live = collect_live_connections t in
  List.iter
    (fun conn ->
      match
        Connection.refresh_auth conn
          ~user:t.config.user_id ~password:token
      with
      | Ok () -> ()
      | Error e -> Observability.record_auth_refresh_failure e)
    live

let force_refresh t =
  let token = sign_now t in
  Atomic.set t.cached_token token;
  push_auth_to_all t token

let spawn_refresh_fiber ~sw t =
  (* [fork_daemon]: refresh-ticking is background-forever work;
     the switch cancels it once all non-daemon fibers (the
     user's actual workload) have exited. A plain [fork] would
     keep the switch alive indefinitely. *)
  Eio.Fiber.fork_daemon ~sw (fun () ->
    let rec loop () =
      Eio.Time.sleep t.clock t.config.refresh_interval;
      (try force_refresh t with
       | Eio.Cancel.Cancelled _ as exn -> raise exn
       | exn ->
           (* Never let the refresh fiber die from a
              transient exception — log and keep ticking.
              Cancellation is the only legitimate exit. *)
           let err =
             Connection.Error.Terminal (Printexc.to_string exn)
           in
           Observability.record_auth_refresh_failure err);
      loop ()
    in
    (try loop ()
     with Eio.Cancel.Cancelled _ -> ());
    `Stop_daemon)

let create ~sw ~clock ~credentials ~config =
  let clock : float Eio.Time.clock_ty Eio.Resource.t =
    (clock :> float Eio.Time.clock_ty Eio.Resource.t)
  in
  (* Eager first sign so [current_token] returns a usable token
     from the moment [create] returns. *)
  let initial =
    Iam_sigv4.presigned_elasticache_token
      ~credentials
      ~region:config.Config.region
      ~cluster_id:config.Config.cluster_id
      ~user_id:config.Config.user_id
      ~now:(Eio.Time.now clock)
  in
  let t = {
    credentials;
    config;
    clock;
    cached_token = Atomic.make initial;
    registrations = Atomic.make [];
  } in
  spawn_refresh_fiber ~sw t;
  t

let auth_provider t =
  Connection.Auth.custom ~name:"iam" (fun () ->
    t.config.user_id, current_token t)

let register t enumerate =
  let reg = { enumerate } in
  let rec loop () =
    let old = Atomic.get t.registrations in
    let next = reg :: old in
    if Atomic.compare_and_set t.registrations old next then reg
    else loop ()
  in
  loop ()

let unregister t reg =
  let rec loop () =
    let old = Atomic.get t.registrations in
    let next = List.filter (fun r -> r != reg) old in
    if Atomic.compare_and_set t.registrations old next then ()
    else loop ()
  in
  loop ()
