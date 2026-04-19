(* Leaderboard on a sorted set.

   Sorted sets store (member, score) pairs ordered by score. The
   classic leaderboard pattern:
     - ZADD player score          add or update a player's score
     - ZINCRBY +1 player          increment by N (atomic)
     - ZREVRANGE 0 9              top 10 (highest scores first)
     - ZREVRANK player            this player's 0-based rank
     - ZRANGEBYSCORE 80 100       all players in [80..100]

   Note: this library currently has typed wrappers for ZRANGE,
   ZRANGEBYSCORE, ZREMRANGEBYSCORE, ZCARD only. Other zset
   commands go through Client.custom. (Adding typed wrappers for
   ZADD/ZINCRBY/ZRANK/ZSCORE is a pending follow-up — see ROADMAP.) *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let board = "leaderboard:weekly"

(* Thin helpers around custom. *)
let zadd client member score =
  C.custom client
    [| "ZADD"; board; string_of_float score; member |]

let zincrby client member by =
  match
    C.custom client
      [| "ZINCRBY"; board; string_of_float by; member |]
  with
  | Ok (Valkey.Resp3.Bulk_string s) -> (try Some (float_of_string s) with _ -> None)
  | _ -> None

let zrevrange_with_scores client ~start ~stop =
  (* RESP3: Array [ Array [Bulk_string member; Double score]; ... ] *)
  match
    C.custom client
      [| "ZRANGE"; board; string_of_int start; string_of_int stop;
         "REV"; "WITHSCORES" |]
  with
  | Ok (Valkey.Resp3.Array items) ->
      List.filter_map
        (function
          | Valkey.Resp3.Array
              [ Valkey.Resp3.Bulk_string m; Valkey.Resp3.Double s ] ->
              Some (m, s)
          | Valkey.Resp3.Array
              [ Valkey.Resp3.Bulk_string m;
                Valkey.Resp3.Bulk_string s ] ->
              (* Defensive: some servers send the score as a bulk
                 string instead of a Double — fall back to parsing. *)
              (try Some (m, float_of_string s) with _ -> None)
          | _ -> None)
        items
  | _ -> []

let zrevrank client member =
  match
    C.custom client [| "ZREVRANK"; board; member |]
  with
  | Ok (Valkey.Resp3.Integer n) -> Some (Int64.to_int n)
  | _ -> None

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    C.connect ~sw
      ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~host:"localhost" ~port:6379 ()
  in

  let _ = C.del client [ board ] in

  (* Seed initial scores. *)
  List.iter
    (fun (player, score) ->
      let _ = zadd client player score in ())
    [ "ada", 100.0; "bob", 75.0; "carol", 120.0;
      "dan", 60.0;  "eve", 90.0;  "frank", 45.0 ];

  (* A few games happen — increment as you go. *)
  let _ = zincrby client "bob" 30.0 in
  let _ = zincrby client "ada" 25.0 in
  let _ = zincrby client "carol" (-10.0) in   (* late penalty *)

  (* Top 5 (highest scores first). *)
  print_endline "\n-- top 5 --";
  let top5 = zrevrange_with_scores client ~start:0 ~stop:4 in
  List.iteri
    (fun i (player, score) ->
      Printf.printf "  %d. %-8s %g\n" (i + 1) player score)
    top5;

  (* Where is bob? *)
  (match zrevrank client "bob" with
   | Some r -> Printf.printf "\nbob is rank %d (0-based)\n" r
   | None -> print_endline "\nbob not on the board");

  (* Range query: who's between 80 and 110 inclusive? *)
  print_endline "\n-- 80..110 (inclusive) --";
  (match
     C.zrangebyscore client board
       ~min:(C.Score 80.0) ~max:(C.Score 110.0)
   with
   | Ok ms -> List.iter (Printf.printf "  %s\n") ms
   | Error e -> Format.eprintf "ZRANGEBYSCORE: %a@." E.pp e);

  (* Total players on the board. *)
  (match C.zcard client board with
   | Ok n -> Printf.printf "\ntotal players: %d\n" n
   | Error e -> Format.eprintf "ZCARD: %a@." E.pp e);

  C.close client
