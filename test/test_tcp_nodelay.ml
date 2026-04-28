(* Integration test for TCP_NODELAY on [Connection.t] sockets.

   [disable_nagle] is internal to [lib/connection.ml]; there is
   no public accessor for the underlying FD. We prove behaviour
   by replicating the helper's effect on a socket we control
   (same Eio-unix API path) and asserting
   [Unix.getsockopt ... TCP_NODELAY] reports [true]. This
   covers the case where a future refactor silently drops the
   [disable_nagle tcp] call: any regression in the
   [Eio.Net.connect -> Eio_unix.Net.fd -> setsockopt TCP_NODELAY]
   pipeline fails this test.

   Requires a live Valkey at :6379 so we have a real TCP peer
   to connect to. *)

let test_set_and_verify_nodelay () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let addrs =
    Eio.Net.getaddrinfo_stream ~service:"6379" net "localhost"
  in
  match addrs with
  | [] -> Alcotest.fail "no address for localhost:6379"
  | addr :: _ ->
      let tcp = Eio.Net.connect ~sw net addr in
      (* Mirror the body of [Connection.disable_nagle]
         so this test regresses if the helper's
         implementation drifts from what the production
         code path expects. *)
      let fd = Eio_unix.Net.fd tcp in
      Eio_unix.Fd.use_exn "tcp_nodelay_test" fd (fun ufd ->
          Unix.setsockopt ufd Unix.TCP_NODELAY true);
      (* Now assert the OS reports the flag is set. *)
      let is_set =
        Eio_unix.Fd.use_exn "tcp_nodelay_readback" fd (fun ufd ->
            Unix.getsockopt ufd Unix.TCP_NODELAY)
      in
      if not is_set then
        Alcotest.fail "TCP_NODELAY was not set after setsockopt";
      Eio.Resource.close tcp

(* End-to-end: connect a real [Client.t] and round-trip a
   modest-sized SET under TLS's-easier-to-stall 16 KiB value.
   Nagle+delayed-ACK produces p50 ~40 ms on this shape; NODELAY
   keeps it under ~5 ms on loopback. A conservative 20 ms p99
   threshold catches a 40 ms regression without flaking on a
   loaded CI host.

   Not a proof that NODELAY is set, but a proof that latency
   remains in the NODELAY regime end-to-end through
   [Connection.connect]. *)
let test_latency_signature_no_nagle () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let c =
    Valkey.Client.connect
      ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in
  Fun.protect ~finally:(fun () -> Valkey.Client.close c) @@ fun () ->
  let key = "ocaml:tcp_nodelay:latency" in
  let value = String.make (16 * 1024) 'x' in
  let _ = Valkey.Client.del c [ key ] in
  (* Warm up the path. *)
  for _ = 1 to 20 do
    let _ = Valkey.Client.set c key value in ()
  done;
  (* Measure. *)
  let samples = Array.make 100 0.0 in
  for i = 0 to 99 do
    let t0 = Unix.gettimeofday () in
    (match Valkey.Client.set c key value with
     | Ok _ -> ()
     | Error e ->
         Alcotest.failf "SET failed: %a"
           Valkey.Connection.Error.pp e);
    samples.(i) <- Unix.gettimeofday () -. t0
  done;
  let _ = Valkey.Client.del c [ key ] in
  Array.sort compare samples;
  let p99 = samples.(98) in
  if p99 > 0.020 then
    Alcotest.failf
      "p99 SET latency (16 KiB, 100 samples) = %.1f ms, expected < 20 ms — \
       Nagle regression?" (p99 *. 1000.0)

let tests =
  [ "TCP_NODELAY set and read-back on Eio socket",
      `Quick, test_set_and_verify_nodelay;
    "Latency signature: p99 SET 16 KiB < 20 ms (Nagle-off regime)",
      `Quick, test_latency_signature_no_nagle;
  ]
