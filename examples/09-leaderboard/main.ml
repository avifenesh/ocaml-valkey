(* Leaderboard on a sorted set.

   Sorted sets store (member, score) pairs ordered by score. The
   classic leaderboard pattern:
     - ZADD player score          add or update a player's score
     - ZINCRBY +1 player          increment by N (atomic)
     - ZRANGE 0 9 REV WITHSCORES  top 10 (highest scores first)
     - ZREVRANK player            this player's 0-based rank
     - ZRANGEBYSCORE 80 100       all players in [80..100] *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let board = "leaderboard:weekly"

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
  (match
     C.zadd client board
       [ 100.0, "ada"; 75.0, "bob"; 120.0, "carol";
         60.0,  "dan"; 90.0, "eve"; 45.0,  "frank" ]
   with
   | Ok n -> Printf.printf "added %d new players\n" n
   | Error e -> Format.eprintf "ZADD: %a@." E.pp e);

  (* A few games happen — increment as you go. *)
  let bump member by =
    match C.zincrby client board ~by ~member with
    | Ok new_score ->
        Printf.printf "  %s now %g\n" member new_score
    | Error e -> Format.eprintf "ZINCRBY: %a@." E.pp e
  in
  print_endline "after games:";
  bump "bob" 30.0;
  bump "ada" 25.0;
  bump "carol" (-10.0);   (* late penalty *)

  (* Top 5 (highest scores first). *)
  print_endline "\n-- top 5 --";
  (match
     C.zrange_with_scores client board ~rev:true ~start:0 ~stop:4
   with
   | Ok pairs ->
       List.iteri
         (fun i (player, score) ->
           Printf.printf "  %d. %-8s %g\n" (i + 1) player score)
         pairs
   | Error e -> Format.eprintf "ZRANGE: %a@." E.pp e);

  (* Where is bob? Two ways. *)
  (match C.zrevrank client board "bob" with
   | Ok (Some r) -> Printf.printf "\nbob is rank %d (0-based)\n" r
   | Ok None -> print_endline "\nbob not on the board"
   | Error e -> Format.eprintf "ZREVRANK: %a@." E.pp e);

  (* WITHSCORE variant gives rank + score in one round-trip. *)
  (match C.zrevrank_with_score client board "bob" with
   | Ok (Some (r, s)) ->
       Printf.printf "  (with WITHSCORE: rank %d, score %g)\n" r s
   | _ -> ());

  (* Range query: who's between 80 and 110 inclusive? *)
  print_endline "\n-- 80..110 (inclusive) --";
  (match
     C.zrangebyscore_with_scores client board
       ~min:(C.Score 80.0) ~max:(C.Score 110.0)
   with
   | Ok pairs ->
       List.iter
         (fun (m, s) -> Printf.printf "  %s (%g)\n" m s)
         pairs
   | Error e -> Format.eprintf "ZRANGEBYSCORE: %a@." E.pp e);

  (* Multi-score lookup. *)
  (match C.zmscore client board [ "ada"; "ghost"; "frank" ] with
   | Ok scores ->
       print_endline "\nZMSCORE [ada; ghost; frank]:";
       List.iter2
         (fun name s ->
           let txt = match s with
             | Some f -> Printf.sprintf "%g" f
             | None -> "nil"
           in
           Printf.printf "  %s -> %s\n" name txt)
         [ "ada"; "ghost"; "frank" ] scores
   | Error e -> Format.eprintf "ZMSCORE: %a@." E.pp e);

  (* Total players on the board. *)
  (match C.zcard client board with
   | Ok n -> Printf.printf "\ntotal players: %d\n" n
   | Error e -> Format.eprintf "ZCARD: %a@." E.pp e);

  (* Pop the top scorer (atomic remove + return). *)
  (match C.zpopmax client board with
   | Ok [ (member, score) ] ->
       Printf.printf "\nweek closed; champion: %s with %g\n" member score
   | Ok [] -> print_endline "\nempty board"
   | Ok _ -> ()
   | Error e -> Format.eprintf "ZPOPMAX: %a@." E.pp e);

  C.close client
