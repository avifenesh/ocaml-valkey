(* Single-instance distributed lock.

   The classic SET <key> <fence> NX EX <ttl> pattern:
     - NX so a stale lock prevents acquisition.
     - EX so a crashed holder's lock self-expires.
     - <fence> is a unique token; release only succeeds if the
       caller is still the owner (compare-and-delete).

   This is *not* Redlock — Redlock spans multiple nodes for
   tolerance to node failure. For one Valkey instance this is the
   simplest correct primitive. For a more robust pattern in
   cluster mode, see https://redis.io/docs/manual/patterns/distributed-locks/

   We demo two workers contending for the same lock; the loser
   waits and retries. *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let lock_key = "lock:invoice:42"
let lock_ttl = 5      (* seconds *)
let max_wait = 3.0    (* seconds *)

let new_fence () =
  Printf.sprintf "%d-%f-%d" (Unix.getpid ()) (Unix.gettimeofday ())
    (Random.bits ())

(* SET NX EX returns true on acquisition. *)
let try_acquire ~client ~fence =
  C.set client lock_key fence
    ~cond:C.Set_nx ~ttl:(C.Set_ex_seconds lock_ttl)

(* Compare-and-delete via custom EVAL — we have no native CAS,
   but a tiny script gets us atomic "delete if value matches". *)
let release ~client ~fence =
  let lua =
    "if redis.call('GET', KEYS[1]) == ARGV[1] then \
       return redis.call('DEL', KEYS[1]) \
     else return 0 end"
  in
  C.custom client
    [| "EVAL"; lua; "1"; lock_key; fence |]

let acquire_with_wait ~client ~clock =
  let fence = new_fence () in
  let deadline = Unix.gettimeofday () +. max_wait in
  let rec loop () =
    match try_acquire ~client ~fence with
    | Ok true -> Some fence
    | Ok false ->
        if Unix.gettimeofday () >= deadline then None
        else begin
          Eio.Time.sleep clock 0.05;
          loop ()
        end
    | Error e ->
        Format.eprintf "SET (lock): %a@." E.pp e;
        None
  in
  loop ()

let work ~client ~clock ~name =
  Printf.printf "[%s] trying to acquire lock\n%!" name;
  match acquire_with_wait ~client ~clock with
  | None ->
      Printf.printf "[%s] gave up after %.1fs\n%!" name max_wait
  | Some fence ->
      Printf.printf "[%s] acquired with fence %s\n%!" name fence;
      (* Critical section. *)
      Eio.Time.sleep clock 0.5;
      Printf.printf "[%s] critical section complete\n%!" name;
      (match release ~client ~fence with
       | Ok (Valkey.Resp3.Integer 1L) ->
           Printf.printf "[%s] released cleanly\n%!" name
       | Ok (Valkey.Resp3.Integer 0L) ->
           Printf.printf
             "[%s] lock had already expired -- nothing to release\n%!" name
       | Ok r ->
           Format.printf "[%s] release: %a\n%!" name Valkey.Resp3.pp r
       | Error e ->
           Format.eprintf "[%s] EVAL: %a@." name E.pp e)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  Random.self_init ();
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let make () =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in
  let setup = make () in
  let _ = C.del setup [ lock_key ] in
  C.close setup;

  let c1 = make () in
  let c2 = make () in
  Eio.Fiber.both
    (fun () -> work ~client:c1 ~clock ~name:"alice")
    (fun () -> work ~client:c2 ~clock ~name:"bob");
  C.close c1;
  C.close c2
