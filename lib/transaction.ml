type state =
  | Open                  (* between MULTI and EXEC/DISCARD *)
  | Finished              (* EXEC or DISCARD succeeded — terminal *)

type t = {
  conn : Connection.t;
  mutable state : state;
  (* Slot the transaction is pinned to (None for standalone). Every
     queued command must hash here or the server returns CROSSSLOT. *)
  pinned_slot : int option;
}

let protocol_violation cmd v =
  Connection.Error.Protocol_violation
    (Format.asprintf "%s: unexpected reply %a" cmd Resp3.pp v)

(* Send a command and expect a SIMPLE_STRING "OK"-like reply. *)
let expect_ok cmd conn args =
  match Connection.request conn args with
  | Error e -> Error e
  | Ok (Resp3.Simple_string "OK") -> Ok ()
  | Ok v -> Error (protocol_violation cmd v)

let resolve_connection client hint_key =
  match hint_key with
  | None ->
      (* Standalone, or cluster without a key hint — grab any
         primary. In cluster the caller is responsible for either
         passing a hint_key or ensuring all their queued keys
         happen to hash to whichever slot this primary owns. *)
      (match Client.connection_for_slot client 0 with
       | Some c -> Ok (c, None)
       | None ->
           Error
             (Connection.Error.Terminal
                "transaction: no live connection"))
  | Some key ->
      let slot = Slot.of_key key in
      (match Client.connection_for_slot client slot with
       | Some c -> Ok (c, Some slot)
       | None ->
           Error
             (Connection.Error.Terminal
                (Printf.sprintf
                   "transaction: no live connection for slot %d \
                    (owner of hint_key %S)"
                   slot key)))

let begin_ ?hint_key ?(watch = []) client =
  match resolve_connection client hint_key with
  | Error e -> Error e
  | Ok (conn, pinned_slot) ->
      let watch_result =
        match watch with
        | [] -> Ok ()
        | keys ->
            let args = Array.of_list ("WATCH" :: keys) in
            expect_ok "WATCH" conn args
      in
      (match watch_result with
       | Error e -> Error e
       | Ok () ->
           (match expect_ok "MULTI" conn [| "MULTI" |] with
            | Error e -> Error e
            | Ok () -> Ok { conn; state = Open; pinned_slot }))

let ensure_open t =
  match t.state with
  | Open -> Ok ()
  | Finished ->
      Error
        (Connection.Error.Terminal
           "transaction: already finished (EXEC or DISCARD already \
            ran); create a new one to queue more commands")

let queue t args =
  match ensure_open t with
  | Error e -> Error e
  | Ok () ->
      (match Connection.request t.conn args with
       | Error e -> Error e
       | Ok (Resp3.Simple_string "QUEUED") -> Ok ()
       | Ok v ->
           (* The server either accepted the command (QUEUED) or
              rejected it (Server_error surfaced via request). Any
              other reply is a protocol violation. *)
           Error (protocol_violation "queue" v))

(* Parse the EXEC reply. RESP3: either an array of per-command
   replies, or Null on a WATCH abort. *)
let parse_exec_reply = function
  | Resp3.Null -> Ok None
  | Resp3.Array items -> Ok (Some items)
  | v -> Error (protocol_violation "EXEC" v)

let exec t =
  match ensure_open t with
  | Error e -> Error e
  | Ok () ->
      let result =
        match Connection.request t.conn [| "EXEC" |] with
        | Error e -> Error e
        | Ok v -> parse_exec_reply v
      in
      t.state <- Finished;
      result

let discard t =
  match ensure_open t with
  | Error e -> Error e
  | Ok () ->
      let result = expect_ok "DISCARD" t.conn [| "DISCARD" |] in
      t.state <- Finished;
      result

let with_transaction ?hint_key ?watch client f =
  match begin_ ?hint_key ?watch client with
  | Error e -> Error e
  | Ok t ->
      (match f t with
       | exception exn ->
           (match discard t with
            | _ -> raise exn)
       | () -> exec t)

(* Ignore pinned_slot's unused warning — we keep it around for future
   same-slot validation of queued commands. *)
let _ = fun t -> t.pinned_slot
