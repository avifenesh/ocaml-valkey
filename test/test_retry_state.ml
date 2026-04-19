(* Retry state-machine tests.

   [Cluster_router.handle_retries] is the centre of the retry logic.
   It takes a [~dispatch] thunk and a [~trigger_refresh] callback,
   inspects the result, and decides whether to sleep and retry or
   surface the error.

   These tests drive it with a SCRIPTED [dispatch] — no real
   connection needed for the non-redirect branches (CLUSTERDOWN,
   TRYAGAIN, Interrupted, Closed). MOVED/ASK branches touch the
   [pool] and [topology_ref] and are exercised by the live-cluster
   integration tests (docker-restart chaos).

   Properties checked:
   - Total dispatches is exactly [1 + successful retries], bounded
     by [max_redirects + 1].
   - [trigger_refresh] fires exactly on CLUSTERDOWN / Interrupted /
     Closed, and NOT on TRYAGAIN.
   - CLUSTERDOWN back-off schedule is 100/200/400/800/1600 ms.
   - Non-retryable errors (e.g. WRONGTYPE) are surfaced immediately
     with zero retries.
*)

module FT = Valkey.Cluster_router.For_testing
module NP = Valkey.Node_pool
module T = Valkey.Topology
module CE = Valkey.Connection.Error

let empty_pool () = NP.create ()

let empty_topology () =
  (* A minimal synthetic topology suffices — the non-redirect
     branches never consult it. *)
  T.single_primary ~host:"127.0.0.1" ~port:6379 ()

(* Sequenced dispatch: takes a list of canned results; each call
   consumes one from the head. Tracks the call count. *)
let scripted_dispatch (rs : (Valkey.Resp3.t, CE.t) result list) =
  let remaining = ref rs in
  let count = ref 0 in
  let dispatch () =
    incr count;
    match !remaining with
    | [] ->
        (* After the script is exhausted, return a terminal error —
           the retry loop shouldn't get here if bounded correctly. *)
        Error
          (CE.Terminal "scripted dispatch exhausted (retry ran too long)")
    | r :: rest ->
        remaining := rest;
        r
  in
  (dispatch, (fun () -> !count))

(* A counter for [trigger_refresh] invocations. *)
let make_refresh_counter () =
  let n = ref 0 in
  let trigger () = incr n in
  (trigger, (fun () -> !n))

let server_err ~code ~message =
  Error (CE.Server_error { code; message })

let clusterdown = server_err ~code:"CLUSTERDOWN" ~message:"down"
let tryagain = server_err ~code:"TRYAGAIN" ~message:"migrating"
let wrongtype = server_err ~code:"WRONGTYPE" ~message:"not a string"
let ok_reply = Ok (Valkey.Resp3.Simple_string "OK")

let run_retry ~max_redirects ~script =
  Eio_main.run @@ fun env ->
  let clock = Eio.Stdenv.clock env in
  let pool = empty_pool () in
  let topology_ref = ref (empty_topology ()) in
  let (dispatch, call_count) = scripted_dispatch script in
  let (trigger_refresh, refresh_count) = make_refresh_counter () in
  let result =
    FT.handle_retries ~pool ~topology_ref ~clock ~max_redirects
      ~trigger_refresh ~dispatch
      [| "GET"; "k" |]
  in
  (result, call_count (), refresh_count ())

(* Same, but also records the wall-clock elapsed time so we can
   cross-check the CLUSTERDOWN schedule. *)
let run_retry_timed ~max_redirects ~script =
  let t0 = Unix.gettimeofday () in
  let (r, c, rc) = run_retry ~max_redirects ~script in
  (r, c, rc, Unix.gettimeofday () -. t0)

(* ---------- tests ---------- *)

let test_ok_first_try () =
  let (result, calls, refreshes) =
    run_retry ~max_redirects:5 ~script:[ ok_reply ]
  in
  (match result with
   | Ok _ -> ()
   | Error e ->
       Alcotest.failf "expected Ok, got %a" CE.pp e);
  Alcotest.(check int) "one dispatch" 1 calls;
  Alcotest.(check int) "no refreshes" 0 refreshes

let test_non_retryable_surface_immediately () =
  let (result, calls, refreshes) =
    run_retry ~max_redirects:5 ~script:[ wrongtype ]
  in
  (match result with
   | Error (CE.Server_error { code = "WRONGTYPE"; _ }) -> ()
   | Ok _ -> Alcotest.fail "expected WRONGTYPE error"
   | Error e ->
       Alcotest.failf "expected WRONGTYPE, got %a" CE.pp e);
  Alcotest.(check int) "exactly one dispatch" 1 calls;
  Alcotest.(check int) "no refreshes for non-retryable" 0 refreshes

let test_tryagain_retries_then_success () =
  let (result, calls, refreshes) =
    run_retry ~max_redirects:5
      ~script:[ tryagain; tryagain; ok_reply ]
  in
  (match result with
   | Ok _ -> ()
   | Error e ->
       Alcotest.failf "expected Ok after TRYAGAIN retries, got %a" CE.pp e);
  Alcotest.(check int) "three dispatches" 3 calls;
  (* TRYAGAIN should NOT trigger refresh. *)
  Alcotest.(check int) "no refreshes for TRYAGAIN" 0 refreshes

let test_clusterdown_retries_then_success () =
  let (result, calls, refreshes, _elapsed) =
    run_retry_timed ~max_redirects:5
      ~script:[ clusterdown; clusterdown; ok_reply ]
  in
  (match result with
   | Ok _ -> ()
   | Error e ->
       Alcotest.failf "expected Ok after CLUSTERDOWN retries, got %a"
         CE.pp e);
  Alcotest.(check int) "three dispatches" 3 calls;
  (* CLUSTERDOWN fires refresh on every retry. *)
  Alcotest.(check int) "two refreshes" 2 refreshes

let test_clusterdown_exhausts_budget () =
  (* Infinite CLUSTERDOWN — should stop after max_redirects retries
     and surface the CLUSTERDOWN error. max_redirects = 3 means:
       call 0 (initial), retry 1, retry 2, retry 3 — 4 dispatches. *)
  let (result, calls, refreshes, elapsed) =
    run_retry_timed ~max_redirects:3
      ~script:[ clusterdown; clusterdown; clusterdown; clusterdown ]
  in
  (match result with
   | Error (CE.Server_error { code = "CLUSTERDOWN"; _ }) -> ()
   | Ok _ -> Alcotest.fail "expected CLUSTERDOWN after budget"
   | Error e ->
       Alcotest.failf "expected CLUSTERDOWN, got %a" CE.pp e);
  Alcotest.(check int) "exactly max_redirects+1 dispatches" 4 calls;
  Alcotest.(check int) "refresh per retry" 3 refreshes;
  (* Timing: 100 + 200 + 400 = 700 ms minimum before the 4th dispatch
     surfaces. Upper bound generous for CI jitter. *)
  if elapsed < 0.65 then
    Alcotest.failf "elapsed %.3fs shorter than expected 700ms \
                    backoff schedule" elapsed;
  if elapsed > 2.5 then
    Alcotest.failf "elapsed %.3fs longer than expected (<2.5s)" elapsed

let test_interrupted_triggers_refresh_and_retries () =
  let interrupted = Error CE.Interrupted in
  let (result, calls, refreshes) =
    run_retry ~max_redirects:5
      ~script:[ interrupted; ok_reply ]
  in
  (match result with
   | Ok _ -> ()
   | Error e ->
       Alcotest.failf "expected Ok after Interrupted, got %a" CE.pp e);
  Alcotest.(check int) "two dispatches" 2 calls;
  Alcotest.(check int) "refresh on Interrupted" 1 refreshes

let test_closed_triggers_refresh_and_retries () =
  let closed = Error CE.Closed in
  let (result, calls, refreshes) =
    run_retry ~max_redirects:5
      ~script:[ closed; closed; ok_reply ]
  in
  (match result with
   | Ok _ -> ()
   | Error e ->
       Alcotest.failf "expected Ok after Closed retries, got %a" CE.pp e);
  Alcotest.(check int) "three dispatches" 3 calls;
  Alcotest.(check int) "refresh per Closed" 2 refreshes

let test_mixed_retryable_errors () =
  (* Blend TRYAGAIN + CLUSTERDOWN + Interrupted in a single run.
     Assert all branches compose without double-counting. *)
  let (result, calls, refreshes) =
    run_retry ~max_redirects:10
      ~script:[ tryagain; clusterdown; Error CE.Interrupted;
                tryagain; ok_reply ]
  in
  (match result with
   | Ok _ -> ()
   | Error e ->
       Alcotest.failf "expected Ok after mixed retries, got %a" CE.pp e);
  Alcotest.(check int) "five dispatches" 5 calls;
  (* Refresh counts: CLUSTERDOWN=1, Interrupted=1, TRYAGAIN=0 × 2 → 2. *)
  Alcotest.(check int) "refresh only on CLUSTERDOWN/Interrupted"
    2 refreshes

(* Direct unit check on the exponential back-off schedule. *)
let test_clusterdown_backoff_schedule () =
  let got = List.init 6 FT.clusterdown_backoff_for_attempt in
  let want = [ 0.1; 0.2; 0.4; 0.8; 1.6; 1.6 ] (* capped *) in
  List.iter2
    (fun g w ->
      if Float.abs (g -. w) > 1e-9 then
        Alcotest.failf "backoff mismatch: got %g want %g" g w)
    got want

let tests =
  [ Alcotest.test_case "ok on first dispatch" `Quick test_ok_first_try;
    Alcotest.test_case "non-retryable surfaces immediately" `Quick
      test_non_retryable_surface_immediately;
    Alcotest.test_case "TRYAGAIN retries without refresh" `Quick
      test_tryagain_retries_then_success;
    Alcotest.test_case "CLUSTERDOWN retries with refresh" `Quick
      test_clusterdown_retries_then_success;
    Alcotest.test_case "CLUSTERDOWN budget + schedule" `Quick
      test_clusterdown_exhausts_budget;
    Alcotest.test_case "Interrupted triggers refresh" `Quick
      test_interrupted_triggers_refresh_and_retries;
    Alcotest.test_case "Closed triggers refresh" `Quick
      test_closed_triggers_refresh_and_retries;
    Alcotest.test_case "mixed retryable errors compose" `Quick
      test_mixed_retryable_errors;
    Alcotest.test_case "CLUSTERDOWN back-off is exponential/capped"
      `Quick test_clusterdown_backoff_schedule;
  ]
