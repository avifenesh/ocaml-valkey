(* Thin wrapper over [Batch]. Atomic mode + optional WATCH guard. *)

module B = Batch

type t = {
  client : Client.t;
  batch : B.t;
  guard : B.guard option;
  mutable finished : bool;
}

let finished_error what =
  Connection.Error.Terminal
    (Printf.sprintf
       "transaction: already finished (EXEC or DISCARD already \
        ran); create a new one to %s more commands" what)

let begin_ ?hint_key ?(watch = []) client =
  let batch = B.create ~atomic:true ?hint_key () in
  match watch with
  | [] -> Ok { client; batch; guard = None; finished = false }
  | keys ->
      (match B.watch ?hint_key client keys with
       | Error e -> Error e
       | Ok guard ->
           Ok { client; batch; guard = Some guard; finished = false })

(* Map a [B.batch_entry_result] back to the flat [Resp3.t] shape
   Transaction has always exposed. Atomic mode rejects fan-out at
   queue time, so [Many] is unreachable here; the [One (Error _)]
   padding only appears if the server returned fewer items than
   queued, which only happens on protocol corruption — still a
   [Resp3.Null] is the least-surprising surface for callers who
   previously saw only well-formed per-command replies. *)
let flatten_entries arr =
  Array.to_list arr
  |> List.map (function
       | B.One (Ok v) -> v
       | B.One (Error _) -> Resp3.Null
       | B.Many _ -> Resp3.Null)

let queue t args =
  if t.finished then Error (finished_error "queue")
  else
    match B.queue t.batch args with
    | Ok () -> Ok ()
    | Error (B.Fan_out_in_atomic_batch cmd) ->
        Error
          (Connection.Error.Terminal
             (Printf.sprintf
                "transaction: fan-out command %S not allowed inside \
                 MULTI/EXEC" cmd))

let exec t =
  if t.finished then Error (finished_error "exec")
  else begin
    t.finished <- true;
    let result =
      match t.guard with
      | Some g -> B.run_with_guard t.batch g
      | None -> B.run t.client t.batch
    in
    match result with
    | Error e -> Error e
    | Ok None -> Ok None
    | Ok (Some arr) -> Ok (Some (flatten_entries arr))
  end

let discard t =
  if t.finished then Error (finished_error "discard")
  else begin
    t.finished <- true;
    (match t.guard with
     | Some g -> B.release_guard g
     | None -> ());
    Ok ()
  end

let with_transaction ?hint_key ?watch client f =
  match begin_ ?hint_key ?watch client with
  | Error e -> Error e
  | Ok t ->
      (match f t with
       | exception exn ->
           (match discard t with _ -> raise exn)
       | () -> exec t)
