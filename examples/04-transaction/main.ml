(* WATCH-based optimistic concurrency.

   Two competing writers each try to credit a balance. Both watch
   the same key, both attempt the read-then-write transaction. The
   first one to commit wins; the loser sees Ok None (WATCH abort)
   and retries.

   To make the race visible, each "writer" sleeps a few ms between
   reading and queuing — that's the window where another writer
   can sneak in. *)

module C = Valkey.Client
module Tx = Valkey.Transaction
module E = Valkey.Connection.Error

let key = "balance:user:42"

let read_int client =
  match C.get client key with
  | Ok (Some s) -> (try int_of_string s with _ -> 0)
  | Ok None -> 0
  | Error e -> Format.eprintf "GET: %a@." E.pp e; 0

let try_credit ~tx_client ~clock ~name ~delta =
  let rec attempt n =
    if n > 5 then begin
      Printf.printf "[%s] giving up after 5 retries\n%!" name;
      None
    end
    else
      let result =
        Tx.with_transaction tx_client ~hint_key:key ~watch:[ key ]
          (fun tx ->
             let current = read_int tx_client in
             Printf.printf "[%s] attempt %d: read %d, will write %d\n%!"
               name n current (current + delta);
             (* Race window — gives the other writer a chance to
                commit a competing write. *)
             Eio.Time.sleep clock 0.05;
             let _ =
               Tx.queue tx
                 [| "SET"; key; string_of_int (current + delta) |]
             in
             ())
      in
      match result with
      | Ok (Some _) ->
          Printf.printf "[%s] committed!\n%!" name;
          Some ()
      | Ok None ->
          Printf.printf "[%s] WATCH abort, retrying\n%!" name;
          attempt (n + 1)
      | Error e ->
          Format.eprintf "[%s] %a@." name E.pp e;
          None
  in
  attempt 1

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let make_client () =
    C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in

  let setup_client = make_client () in
  let _ = C.set setup_client key "100" in
  C.close setup_client;

  (* Two transactional clients race. *)
  let t1 = make_client () in
  let t2 = make_client () in
  Eio.Fiber.both
    (fun () -> ignore (try_credit ~tx_client:t1 ~clock ~name:"alice" ~delta:25))
    (fun () -> ignore (try_credit ~tx_client:t2 ~clock ~name:"bob"   ~delta:50));
  C.close t1;
  C.close t2;

  let final_client = make_client () in
  let final = read_int final_client in
  Printf.printf "\nfinal balance: %d (expected 175)\n" final;
  C.close final_client
