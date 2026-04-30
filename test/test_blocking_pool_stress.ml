(* Stress test for Blocking_pool — closes the ROADMAP §Phase 9
   success criterion: "1000 concurrent BLPOP callers with a cap
   of 100 connections, bounded wait, no leaks."

   Standalone only (single-node) so CI cost is one
   [docker compose up -d]. Gated behind [STRESS=1]; the default
   CI path skips. Scaled knobs live at the top of the file for
   operators who want to turn them up on beefier hardware.

   Shape:
     - [max_per_node = 100], [on_exhaustion = `Block],
       [borrow_timeout = Some 5.0].
     - 1000 consumer fibers, each [blpop ~keys:[queue]
       ~block_seconds:2.0].
     - Producer fiber pushes 1000 items over ~5 s via [rpush].
     - Whole test wrapped in [Eio.Time.with_timeout] (30 s).
     - Asserts: every call returned [Ok _] (no borrow errors, no
       transport errors); [total_borrowed >= callers];
       [total_borrow_timeouts = 0]; [total_exhaustion_rejects =
       0]; [total_closed_dirty = 0]; [in_use = 0] at the end.

   Not a benchmark — numbers aren't recorded. A pass means the
   pool survives contention at the design cap without leaks or
   typed-error surprises. *)

module C = Valkey.Client
module BP = Valkey.Blocking_pool

let host = "localhost"
let port = 6379
let queue = "ocaml:bps:stress:q"

let callers = 1000
let max_per_node = 100
let producer_rate_per_second = 200.0  (* ~5s to drain the queue *)
let test_timeout_seconds = 30.0

let stress_enabled () =
  try Sys.getenv "STRESS" = "1" with Not_found -> false

let skipped name =
  Alcotest.test_case name `Quick (fun () ->
    Printf.printf "(skipped: set STRESS=1 to enable)%!")

(* Build the stress client with the operator-cap configuration. *)
let with_stress_client f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let pool =
    { BP.Config.default with
      max_per_node;
      on_exhaustion = `Block;
      borrow_timeout = Some 5.0;
      min_idle_per_node = 0;
    }
  in
  let config = { C.Config.default with blocking_pool = pool } in
  let c = C.connect ~sw ~net ~clock ~config ~host ~port () in
  let r =
    try f env clock c
    with e -> C.close c; raise e
  in
  C.close c;
  r

(* One consumer: a single BLPOP call. Returns [Ok ()] on clean
   (Some _) or clean (None — server-side timeout); [Error msg]
   otherwise so we can assert over the full set after join. *)
let run_consumer client =
  match C.blpop client ~keys:[ queue ] ~block_seconds:2.0 with
  | Ok (Some _) -> Ok ()
  | Ok None -> Ok ()  (* server-side timeout is clean *)
  | Error e ->
      Error (Format.asprintf "%a" C.pp_blocking_error e)

(* Producer: [n] RPUSHes evenly spaced across the test window.
   Uses non-blocking [rpush] on the multiplexed client — the whole
   point of the pool is that regular traffic keeps flowing while
   blocking consumers hang on the dedicated leases. *)
let run_producer ~clock ~client ~n =
  let gap = 1.0 /. producer_rate_per_second in
  for i = 0 to n - 1 do
    (match C.rpush client queue
             [ Printf.sprintf "job-%d" i ] with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "producer RPUSH %d: %a"
           i Valkey.Connection.Error.pp e);
    Eio.Time.sleep clock gap
  done

let test_thousand_callers () =
  if not (stress_enabled ()) then
    Printf.printf "(skipped: STRESS=1 to enable)%!"
  else
    with_stress_client @@ fun _env clock c ->
    let _ = C.del c [ queue ] in
    let results : (unit, string) result array =
      Array.make callers (Ok ())
    in
    let run () =
      Eio.Fiber.both
        (fun () -> run_producer ~clock ~client:c ~n:callers)
        (fun () ->
          Eio.Fiber.List.iter
            (fun i -> results.(i) <- run_consumer c)
            (List.init callers Fun.id))
    in
    (match
       Eio.Time.with_timeout clock test_timeout_seconds
         (fun () -> run (); Ok ())
     with
     | Ok () -> ()
     | Error `Timeout ->
         Alcotest.failf
           "stress test exceeded %.0fs wall-clock budget"
           test_timeout_seconds);
    (* Every caller must have returned a clean result. *)
    let errors =
      Array.to_list results
      |> List.filter_map (function Ok () -> None | Error s -> Some s)
    in
    if errors <> [] then
      Alcotest.failf "caller errors (%d of %d): first = %s"
        (List.length errors) callers (List.hd errors);
    (* Final stats: every borrow returned cleanly; no timeouts,
       no exhaustion rejects, no dirty closes; no in-flight lease. *)
    (match C.For_testing.blocking_pool c with
     | None -> Alcotest.fail "blocking_pool should be Some _ under stress"
     | Some pool ->
         let s = BP.stats pool in
         if s.total_borrowed < callers then
           Alcotest.failf "expected total_borrowed >= %d, got %d"
             callers s.total_borrowed;
         if s.total_borrow_timeouts <> 0 then
           Alcotest.failf "expected zero borrow timeouts, got %d"
             s.total_borrow_timeouts;
         if s.total_exhaustion_rejects <> 0 then
           Alcotest.failf "expected zero exhaustion rejects, got %d"
             s.total_exhaustion_rejects;
         if s.total_closed_dirty <> 0 then
           Alcotest.failf
             "expected zero dirty closes, got %d (cancellation or \
              topology churn during stress run)"
             s.total_closed_dirty;
         if s.in_use <> 0 then
           Alcotest.failf
             "expected in_use = 0 after join, got %d (leaked lease)"
             s.in_use;
         if s.total_created > max_per_node then
           Alcotest.failf
             "expected total_created <= max_per_node (%d), got %d"
             max_per_node s.total_created);
    let _ = C.del c [ queue ] in
    ()

let tests =
  [ (if stress_enabled () then
       Alcotest.test_case
         "1000 concurrent BLPOP callers, max_per_node=100"
         `Slow test_thousand_callers
     else
       skipped "1000 concurrent BLPOP callers (STRESS=1 to enable)")
  ]
