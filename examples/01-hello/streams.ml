(* Streams: append-only log structure.

   Append entries with XADD. Each entry has a server-assigned
   monotonic ID and a list of (field, value) pairs. Read with
   XRANGE for replay or XREAD for tailing.

   Consumer groups (XREADGROUP / XACK) are in streams_groups.ml. *)

module C = Valkey.Client
module E = Valkey.Connection.Error

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    C.connect ~sw
      ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~host:"localhost" ~port:6379 ()
  in
  let stream = "events:hello" in

  (* Trim everything from previous runs. *)
  let _ = C.del client [ stream ] in

  (* Append three entries. The server returns the assigned ID
     (timestamp-millis-seq), useful for cross-references. *)
  let ids =
    List.filter_map
      (fun fields ->
        match C.xadd client stream fields with
        | Ok id ->
            Printf.printf "appended %s\n" id;
            Some id
        | Error e ->
            Format.eprintf "XADD: %a@." E.pp e;
            None)
      [ [ "type", "signup"; "user", "alice" ];
        [ "type", "purchase"; "user", "bob"; "amount", "29" ];
        [ "type", "signup"; "user", "carol" ] ]
  in

  Printf.printf "stream length: %d\n"
    (match C.xlen client stream with Ok n -> n | Error _ -> -1);

  (* Replay from the start. "-" / "+" denote earliest / latest IDs. *)
  Printf.printf "\n-- xrange (replay) --\n";
  (match C.xrange client stream ~start:"-" ~end_:"+" with
   | Ok entries ->
       List.iter
         (fun (e : C.stream_entry) ->
           Printf.printf "  %s : " e.id;
           List.iter (fun (k, v) -> Printf.printf "%s=%s " k v) e.fields;
           print_newline ())
         entries
   | Error e -> Format.eprintf "XRANGE: %a@." E.pp e);

  (* Tail from the last seen ID. Pass "0" to start from earliest;
     here we start "after the second entry" to demonstrate cursor
     positioning. *)
  let after =
    match List.nth_opt ids 1 with Some id -> id | None -> "0"
  in
  Printf.printf "\n-- xread starting after %s --\n" after;
  (match
     C.xread client ~count:10 ~streams:[ stream, after ]
   with
   | Ok results ->
       List.iter
         (fun (s, entries) ->
           Printf.printf "  stream %s: %d entries\n"
             s (List.length entries);
           List.iter
             (fun (e : C.stream_entry) ->
               Printf.printf "    %s\n" e.id)
             entries)
         results
   | Error e -> Format.eprintf "XREAD: %a@." E.pp e);

  C.close client
