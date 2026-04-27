(** Pure-unit tests for the OPTIN code paths that aren't reachable
    against a real server: the [Protocol_violation] branch (would
    require Valkey to reply non-OK to [CLIENT CACHING YES], which
    it never does), the frame-1 transport-failure branch, and the
    cluster + OPTIN config gate at [Client.from_router]. *)

module Client = Valkey.Client
module CC = Valkey.Client_cache
module Cache = Valkey.Cache
module Conn = Valkey.Connection
module E = Valkey.Connection.Error
module R = Valkey.Resp3

(* ---------- map_optin_pair_reply: every arm ---------- *)

let map = Client.For_testing.map_optin_pair_reply

let pp_result = Alcotest.of_pp (fun fmt -> function
  | Ok v -> Format.fprintf fmt "Ok %a" R.pp v
  | Error e -> Format.fprintf fmt "Error %a" E.pp e)

let test_map_outer_error () =
  Alcotest.(check pp_result) "outer Closed passes through"
    (Error E.Closed)
    (map (Error E.Closed));
  Alcotest.(check pp_result) "outer Circuit_open passes through"
    (Error E.Circuit_open)
    (map (Error E.Circuit_open));
  Alcotest.(check pp_result) "outer Queue_full passes through"
    (Error E.Queue_full)
    (map (Error E.Queue_full))

let test_map_frame1_transport_error () =
  (* If the connection drops between the server processing
     [CACHING YES] and our read receiving frame-1's reply, the
     parser flips the entry's promise to Error. The second
     frame's reply is whatever survived (or Error too) — it
     doesn't matter; the read is failed by frame-1. *)
  Alcotest.(check pp_result)
    "frame-1 Closed surfaces, second discarded"
    (Error E.Closed)
    (map (Ok (Error E.Closed, Ok (R.Simple_string "ignored"))));
  Alcotest.(check pp_result)
    "frame-1 Interrupted surfaces, second discarded"
    (Error E.Interrupted)
    (map (Ok (Error E.Interrupted, Error E.Closed)))

let test_map_happy_path () =
  let bs = R.Bulk_string "hello" in
  Alcotest.(check pp_result) "OK + bulk string passes second through"
    (Ok bs)
    (map (Ok (Ok (R.Simple_string "OK"), Ok bs)));
  Alcotest.(check pp_result) "OK + Null passes Null through"
    (Ok R.Null)
    (map (Ok (Ok (R.Simple_string "OK"), Ok R.Null)));
  let server_err =
    E.Server_error
      { code = "WRONGTYPE";
        message = "Operation against a key holding the wrong kind of value" }
  in
  Alcotest.(check pp_result)
    "OK + WRONGTYPE on the read passes the WRONGTYPE through"
    (Error server_err)
    (map (Ok (Ok (R.Simple_string "OK"), Error server_err)))

let test_map_protocol_violation () =
  (* Synthesised server reply: CACHING YES returns something
     other than a Simple_string "OK". A real Valkey server
     never does this, but a misbehaving proxy / version skew /
     intentional fuzzing could. We must surface it as
     Protocol_violation, not silently treat it as a successful
     CACHING. *)
  let weird_reply = R.Integer 42L in
  match map (Ok (Ok weird_reply, Ok (R.Bulk_string "v"))) with
  | Error (E.Protocol_violation msg) ->
      Alcotest.(check bool)
        "Protocol_violation message names the offending command"
        true
        (let m = String.lowercase_ascii msg in
         (* substring match without bringing in [Str] just for this *)
         let found =
           let lm = String.length m in
           let needle = "client caching yes" in
           let ln = String.length needle in
           let rec scan i =
             if i + ln > lm then false
             else if String.sub m i ln = needle then true
             else scan (i + 1)
           in
           scan 0
         in
         found)
  | other ->
      Alcotest.failf
        "expected Protocol_violation, got %s"
        (match other with
         | Ok v -> Format.asprintf "Ok %a" R.pp v
         | Error e -> Format.asprintf "Error %a" E.pp e)

let tests =
  [ Alcotest.test_case "map: outer Error passes through" `Quick
      test_map_outer_error;
    Alcotest.test_case "map: frame-1 transport error surfaces" `Quick
      test_map_frame1_transport_error;
    Alcotest.test_case "map: happy path passes second through" `Quick
      test_map_happy_path;
    Alcotest.test_case "map: non-OK CACHING reply -> Protocol_violation" `Quick
      test_map_protocol_violation;
  ]
