(** B6b: MGET scatter-gather over cache state.

    Verifies MGET splits into (hit, batch-miss, joining) groups,
    issues one wire MGET for the batch-miss subset only, and
    merges all three groups back into input order.

    Requires live Valkey >= 7.4 on [localhost:6379]. *)

module C = Valkey.Client
module Cfg = Valkey.Client.Config
module Cache = Valkey.Cache
module R = Valkey.Resp3
module E = Valkey.Connection.Error

let host = "localhost"
let port = 6379

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

(* Parse keyspace_hits out of an INFO stats reply. *)
let parse_keyspace_hits = function
  | R.Bulk_string s | R.Simple_string s
  | R.Verbatim_string { data = s; _ } ->
      (try
         let re = Str.regexp "keyspace_hits:\\([0-9]+\\)" in
         let _ = Str.search_forward re s 0 in
         int_of_string (Str.matched_group 1 s)
       with Not_found -> 0)
  | _ -> 0

(* Count total GET-family hits on the server, used to measure
   how many wire reads our MGET caused. Each server-side MGET of
   K keys produces K keyspace_hits; so measuring the *delta* in
   keyspace_hits tells us exactly how many keys the server saw
   us read. *)
let keyspace_hits aux =
  match C.exec aux [| "INFO"; "stats" |] with
  | Ok v -> parse_keyspace_hits v
  | Error e -> Alcotest.failf "INFO: %a" E.pp e

let reset_stats aux =
  let _ = C.exec aux [| "CONFIG"; "RESETSTAT" |] in ()

(* --- All-miss: one wire MGET, all values cached ----------------- *)

let test_mget_all_miss_one_wire () =
  let keys = [ "ocaml:csc:mget:m1"; "ocaml:csc:mget:m2"; "ocaml:csc:mget:m3" ] in
  with_csc ~keys @@ fun _env client cache aux ->
  List.iter2
    (fun k v -> let _ = C.exec aux [| "SET"; k; v |] in ())
    keys [ "v1"; "v2"; "v3" ];
  reset_stats aux;
  let h0 = keyspace_hits aux in
  (match C.mget client keys with
   | Ok vs ->
       Alcotest.(check (list (option string))) "mget result"
         [ Some "v1"; Some "v2"; Some "v3" ] vs
   | Error e -> Alcotest.failf "MGET: %a" E.pp e);
  let h1 = keyspace_hits aux in
  Alcotest.(check int) "server saw 3 key reads" 3 (h1 - h0);
  Alcotest.(check int) "all 3 cached" 3
    (List.length (List.filter (fun k -> Option.is_some (Cache.get cache k)) keys))

(* --- All-hit: no wire at all ----------------------------------- *)

let test_mget_all_hit_zero_wire () =
  let keys = [ "ocaml:csc:mget:h1"; "ocaml:csc:mget:h2" ] in
  with_csc ~keys @@ fun _env client _cache aux ->
  List.iter2
    (fun k v -> let _ = C.exec aux [| "SET"; k; v |] in ())
    keys [ "v1"; "v2" ];
  (* Prime the cache via single-key GETs. *)
  let _ = C.get client (List.nth keys 0) in
  let _ = C.get client (List.nth keys 1) in
  reset_stats aux;
  let h0 = keyspace_hits aux in
  (match C.mget client keys with
   | Ok [ Some "v1"; Some "v2" ] -> ()
   | Ok other ->
       Alcotest.failf "unexpected %s"
         (String.concat ", "
            (List.map (function Some s -> s | None -> "None") other))
   | Error e -> Alcotest.failf "MGET: %a" E.pp e);
  let h1 = keyspace_hits aux in
  Alcotest.(check int) "no wire reads on all-cached MGET"
    0 (h1 - h0)

(* --- Partial hit: only miss subset hits the wire ---------------- *)

let test_mget_partial_hit () =
  let cached_k = "ocaml:csc:mget:p1" in
  let miss_k = "ocaml:csc:mget:p2" in
  let keys = [ cached_k; miss_k ] in
  with_csc ~keys @@ fun _env client cache aux ->
  let _ = C.exec aux [| "SET"; cached_k; "v1" |] in
  let _ = C.exec aux [| "SET"; miss_k; "v2" |] in
  (* Cache cached_k via a GET. *)
  let _ = C.get client cached_k in
  Alcotest.(check bool) "cached_k cached" true
    (Option.is_some (Cache.get cache cached_k));
  reset_stats aux;
  let h0 = keyspace_hits aux in
  (match C.mget client keys with
   | Ok [ Some "v1"; Some "v2" ] -> ()
   | Ok _ -> Alcotest.fail "wrong values"
   | Error e -> Alcotest.failf "MGET: %a" E.pp e);
  let h1 = keyspace_hits aux in
  Alcotest.(check int) "only the one miss hit the wire"
    1 (h1 - h0);
  (* Both are cached now. *)
  Alcotest.(check bool) "miss_k cached after mget" true
    (Option.is_some (Cache.get cache miss_k))

(* --- Null elements not cached (matches GET) --------------------- *)

let test_mget_null_not_cached () =
  let k1 = "ocaml:csc:mget:n1" in
  let k2 = "ocaml:csc:mget:n2" in
  with_csc ~keys:[k1; k2] @@ fun _env client cache _aux ->
  (* Both start missing. *)
  (match C.mget client [k1; k2] with
   | Ok [ None; None ] -> ()
   | _ -> Alcotest.fail "expected two Nones");
  Alcotest.(check (option reject)) "k1 not cached (Null)" None
    (Cache.get cache k1);
  Alcotest.(check (option reject)) "k2 not cached (Null)" None
    (Cache.get cache k2)

(* --- External write mid-MGET invalidates the cached entry ------- *)

let test_mget_external_set_invalidates_cached_entry () =
  let k = "ocaml:csc:mget:evict" in
  with_csc ~keys:[k] @@ fun env client cache aux ->
  let _ = C.exec aux [| "SET"; k; "v1" |] in
  let _ = C.mget client [k] in
  Alcotest.(check bool) "cached" true (Option.is_some (Cache.get cache k));
  let _ = C.exec aux [| "SET"; k; "v2" |] in
  Eio.Time.sleep (Eio.Stdenv.clock env) 0.05;
  Alcotest.(check (option reject)) "evicted" None (Cache.get cache k)

let tests =
  [ Alcotest.test_case "mget all-miss → one wire, all cached" `Quick
      test_mget_all_miss_one_wire;
    Alcotest.test_case "mget all-hit → zero wire" `Quick
      test_mget_all_hit_zero_wire;
    Alcotest.test_case "mget partial hit → miss-only wire" `Quick
      test_mget_partial_hit;
    Alcotest.test_case "mget null elements not cached" `Quick
      test_mget_null_not_cached;
    Alcotest.test_case "mget external SET evicts cached entry" `Quick
      test_mget_external_set_invalidates_cached_entry;
  ]
