(* Integration tests for MULTI / EXEC / WATCH. Requires the
   standalone Valkey at :6379. *)

module C = Valkey.Client
module T = Valkey.Transaction
module E = Valkey.Connection.Error
module R = Valkey.Resp3

let with_client f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let c = C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 () in
  Fun.protect ~finally:(fun () -> C.close c) (fun () -> f c)

let err_pp = E.pp

let check_ok msg = function
  | Ok () -> ()
  | Error e -> Alcotest.failf "%s: %a" msg err_pp e

let test_basic_multi_exec () =
  with_client @@ fun c ->
  let _ = C.del c [ "tx:a"; "tx:b" ] in
  match T.begin_ c with
  | Error e -> Alcotest.failf "begin_: %a" err_pp e
  | Ok t ->
      check_ok "queue SET a"
        (T.queue t [| "SET"; "tx:a"; "1" |]);
      check_ok "queue SET b"
        (T.queue t [| "SET"; "tx:b"; "2" |]);
      check_ok "queue INCR a"
        (T.queue t [| "INCR"; "tx:a" |]);
      (match T.exec t with
       | Error e -> Alcotest.failf "exec: %a" err_pp e
       | Ok None -> Alcotest.fail "unexpected watch abort"
       | Ok (Some replies) ->
           Alcotest.(check int) "reply count" 3 (List.length replies);
           (match replies with
            | [ R.Simple_string "OK"; R.Simple_string "OK";
                R.Integer 2L ] -> ()
            | _ ->
                Alcotest.failf "unexpected replies: %s"
                  (String.concat ", "
                     (List.map (Format.asprintf "%a" R.pp) replies))))

let test_discard () =
  with_client @@ fun c ->
  let _ = C.del c [ "tx:d" ] in
  let _ = C.set c "tx:d" "before" in
  (match T.begin_ c with
   | Error e -> Alcotest.failf "begin_: %a" err_pp e
   | Ok t ->
       check_ok "queue" (T.queue t [| "SET"; "tx:d"; "after" |]);
       check_ok "discard" (T.discard t));
  (match C.get c "tx:d" with
   | Ok (Some v) ->
       Alcotest.(check string) "value untouched" "before" v
   | Ok None -> Alcotest.fail "key vanished"
   | Error e -> Alcotest.failf "GET: %a" err_pp e);
  ignore (C.del c [ "tx:d" ])

let test_watch_abort () =
  (* Need two independent clients in the same Eio_main.run so we can
     cause a concurrent modification against the watched key. *)
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let c = C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 () in
  let c2 = C.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 () in
  Fun.protect
    ~finally:(fun () -> C.close c; C.close c2)
  @@ fun () ->
  let _ = C.del c [ "tx:w" ] in
  let _ = C.set c "tx:w" "0" in
  match T.begin_ c ~watch:[ "tx:w" ] with
  | Error e -> Alcotest.failf "begin_: %a" err_pp e
  | Ok t ->
      (* Concurrent modification via the second client — WATCH fires. *)
      (match C.set c2 "tx:w" "changed" with
       | Ok _ -> ()
       | Error e -> Alcotest.failf "concurrent SET: %a" err_pp e);
      check_ok "queue INCR"
        (T.queue t [| "INCR"; "tx:w" |]);
      (match T.exec t with
       | Error e -> Alcotest.failf "exec: %a" err_pp e
       | Ok (Some _) ->
           Alcotest.fail "expected watch abort (Ok None), got commit"
       | Ok None -> ());
      ignore (C.del c [ "tx:w" ])

let test_with_transaction_helper () =
  with_client @@ fun c ->
  let _ = C.del c [ "tx:h" ] in
  match
    T.with_transaction c @@ fun t ->
    check_ok "SET" (T.queue t [| "SET"; "tx:h"; "42" |]);
    check_ok "INCR" (T.queue t [| "INCR"; "tx:h" |])
  with
  | Error e -> Alcotest.failf "with_transaction: %a" err_pp e
  | Ok None -> Alcotest.fail "unexpected watch abort"
  | Ok (Some replies) ->
      Alcotest.(check int) "reply count" 2 (List.length replies);
      (match replies with
       | [ R.Simple_string "OK"; R.Integer 43L ] -> ()
       | _ ->
           Alcotest.failf "unexpected replies: %s"
             (String.concat ", "
                (List.map (Format.asprintf "%a" R.pp) replies)));
      ignore (C.del c [ "tx:h" ])

let test_double_exec_rejected () =
  with_client @@ fun c ->
  let _ = C.del c [ "tx:x" ] in
  match T.begin_ c with
  | Error e -> Alcotest.failf "begin_: %a" err_pp e
  | Ok t ->
      check_ok "queue" (T.queue t [| "SET"; "tx:x"; "1" |]);
      (match T.exec t with
       | Error e -> Alcotest.failf "first exec: %a" err_pp e
       | Ok _ -> ());
      (* Second exec should be rejected - transaction is finished. *)
      (match T.exec t with
       | Error (E.Terminal _) -> ()
       | Ok _ -> Alcotest.fail "expected second EXEC to fail"
       | Error e ->
           Alcotest.failf "unexpected error: %a" err_pp e);
      ignore (C.del c [ "tx:x" ])

let tests =
  [ Alcotest.test_case "MULTI/EXEC basic roundtrip" `Quick
      test_basic_multi_exec;
    Alcotest.test_case "DISCARD leaves keys untouched" `Quick
      test_discard;
    Alcotest.test_case "WATCH aborts on concurrent change" `Quick
      test_watch_abort;
    Alcotest.test_case "with_transaction helper" `Quick
      test_with_transaction_helper;
    Alcotest.test_case "second EXEC on same handle errors" `Quick
      test_double_exec_rejected;
  ]
