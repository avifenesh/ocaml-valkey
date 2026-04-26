(** B6a: HGETALL + SMEMBERS cache coverage.

    Same shape as GET but value types differ. Requires live Valkey
    >= 7.4 on [localhost:6379]. *)

module C = Valkey.Client
module Cfg = Valkey.Client.Config
module Cache = Valkey.Cache
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let host = "localhost"
let port = 6379
let grace_s = 0.05

let sleep_ms env ms =
  Eio.Time.sleep (Eio.Stdenv.clock env) (ms /. 1000.0)

let with_csc ~keys f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let cache = Cache.create ~byte_budget:(1024 * 1024) in
  let ccfg = Valkey.Client_cache.make ~cache () in
  let client =
    C.connect ~sw ~net ~clock
      ~config:{ Cfg.default with client_cache = Some ccfg }
      ~host ~port ()
  in
  let aux = C.connect ~sw ~net ~clock ~host ~port () in
  let cleanup () = List.iter (fun k -> let _ = C.del aux [k] in ()) keys in
  cleanup ();
  let finally () = cleanup (); C.close client; C.close aux in
  Fun.protect ~finally (fun () -> f env client cache aux)

(* --- HGETALL --------------------------------------------------- *)

let test_hgetall_populates_then_hits () =
  let k = "ocaml:csc:hgetall:k" in
  with_csc ~keys:[k] @@ fun _env client cache aux ->
  let _ = C.hset aux k [ "f1", "v1"; "f2", "v2" ] in
  (match C.hgetall client k with
   | Ok pairs ->
       let sorted = List.sort compare pairs in
       Alcotest.(check (list (pair string string)))
         "first hgetall"
         [ "f1", "v1"; "f2", "v2" ] sorted
   | Error e -> Alcotest.failf "HGETALL: %a" E.pp e);
  Alcotest.(check bool) "cache populated" true
    (Option.is_some (Cache.get cache k));
  (* Second call should cache-hit; just verify it returns the same
     payload. *)
  match C.hgetall client k with
  | Ok pairs ->
      let sorted = List.sort compare pairs in
      Alcotest.(check (list (pair string string)))
        "second hgetall (cached)"
        [ "f1", "v1"; "f2", "v2" ] sorted
  | Error e -> Alcotest.failf "cached HGETALL: %a" E.pp e

let test_hgetall_external_hset_evicts () =
  let k = "ocaml:csc:hgetall:evict" in
  with_csc ~keys:[k] @@ fun env client cache aux ->
  let _ = C.hset aux k [ "f", "v1" ] in
  let _ = C.hgetall client k in
  Alcotest.(check bool) "cached" true
    (Option.is_some (Cache.get cache k));
  let _ = C.hset aux k [ "f", "v2" ] in
  sleep_ms env (grace_s *. 1000.0);
  Alcotest.(check (option reject)) "evicted after external HSET"
    None (Cache.get cache k)

(* --- SMEMBERS -------------------------------------------------- *)

let test_smembers_populates_then_hits () =
  let k = "ocaml:csc:smembers:k" in
  with_csc ~keys:[k] @@ fun _env client cache aux ->
  let _ = C.sadd aux k [ "a"; "b"; "c" ] in
  (match C.smembers client k with
   | Ok xs ->
       let sorted = List.sort compare xs in
       Alcotest.(check (list string)) "first smembers"
         [ "a"; "b"; "c" ] sorted
   | Error e -> Alcotest.failf "SMEMBERS: %a" E.pp e);
  Alcotest.(check bool) "cache populated" true
    (Option.is_some (Cache.get cache k));
  match C.smembers client k with
  | Ok xs ->
      let sorted = List.sort compare xs in
      Alcotest.(check (list string)) "second smembers (cached)"
        [ "a"; "b"; "c" ] sorted
  | Error e -> Alcotest.failf "cached SMEMBERS: %a" E.pp e

let test_smembers_external_sadd_evicts () =
  let k = "ocaml:csc:smembers:evict" in
  with_csc ~keys:[k] @@ fun env client cache aux ->
  let _ = C.sadd aux k [ "a" ] in
  let _ = C.smembers client k in
  Alcotest.(check bool) "cached" true
    (Option.is_some (Cache.get cache k));
  let _ = C.sadd aux k [ "b" ] in
  sleep_ms env (grace_s *. 1000.0);
  Alcotest.(check (option reject)) "evicted after external SADD"
    None (Cache.get cache k)

let tests =
  [ Alcotest.test_case "hgetall miss then hit" `Quick
      test_hgetall_populates_then_hits;
    Alcotest.test_case "hgetall evicted on external HSET" `Quick
      test_hgetall_external_hset_evicts;
    Alcotest.test_case "smembers miss then hit" `Quick
      test_smembers_populates_then_hits;
    Alcotest.test_case "smembers evicted on external SADD" `Quick
      test_smembers_external_sadd_evicts;
  ]
