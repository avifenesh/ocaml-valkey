(* See batch.mli for the conceptual model. *)

type queue_error =
  | Fan_out_in_atomic_batch of string

type batch_entry_result =
  | One of (Resp3.t, Connection.Error.t) result
  | Many of (string * (Resp3.t, Connection.Error.t) result) list

type queued = {
  args : string array;
  spec : Command_spec.t;
  index : int;
}

type t = {
  atomic : bool;
  hint_key : string option;
  watch : string list;
  mutable queued : queued list;    (* reversed; reversed again on run *)
  mutable count : int;
}

let create ?(atomic = false) ?hint_key ?(watch = []) () =
  { atomic; hint_key; watch; queued = []; count = 0 }

let is_atomic t = t.atomic

let length t = t.count

let command_name_of args =
  if Array.length args = 0 then ""
  else String.uppercase_ascii args.(0)

let is_fan_out = function
  | Command_spec.Fan_primaries | Command_spec.Fan_all_nodes -> true
  | _ -> false

let queue t args =
  let spec = Command_spec.lookup args in
  if t.atomic && is_fan_out spec then
    Error (Fan_out_in_atomic_batch (command_name_of args))
  else begin
    let index = t.count in
    t.queued <- { args; spec; index } :: t.queued;
    t.count <- index + 1;
    Ok ()
  end

(* Wall-clock deadline, then ?timeout passed to each Client.exec /
   exec_multi call is the remaining window. Commands that start
   with zero window left will time out immediately. Fibers are
   all spawned in parallel via Fiber.List.iter so the nominal
   batch duration is [max over commands of their execution time]
   rather than [sum]. *)
let remaining_window ~deadline =
  match deadline with
  | None -> None
  | Some d ->
      let left = d -. Unix.gettimeofday () in
      (* Never pass a non-positive timeout; use a tiny positive
         value to signal "fire and time out immediately". *)
      Some (Float.max 0.001 left)

let dispatch_one client raw ~deadline q =
  let per_timeout = remaining_window ~deadline in
  let result : batch_entry_result =
    match q.spec with
    | Command_spec.Fan_primaries ->
        let rs =
          Client.exec_multi ?timeout:per_timeout
            ~fan:Router.Fan_target.All_primaries client q.args
        in
        Many rs
    | Command_spec.Fan_all_nodes ->
        let rs =
          Client.exec_multi ?timeout:per_timeout
            ~fan:Router.Fan_target.All_nodes client q.args
        in
        Many rs
    | _ ->
        One (Client.exec ?timeout:per_timeout client q.args)
  in
  raw.(q.index) <- Some result

let run_non_atomic ?timeout client t =
  let entries = List.rev t.queued in
  let raw = Array.make t.count None in
  let deadline =
    match timeout with
    | None -> None
    | Some s -> Some (Unix.gettimeofday () +. s)
  in
  Eio.Fiber.List.iter (dispatch_one client raw ~deadline) entries;
  let finalized =
    Array.map
      (function
        | Some r -> r
        | None -> One (Error Connection.Error.Timeout))
      raw
  in
  Ok (Some finalized)

let run ?timeout client t =
  if t.atomic then
    Error
      (Connection.Error.Terminal
         "Batch.run: atomic mode pending — use Transaction for now")
  else begin
    let _ = t.hint_key in
    let _ = t.watch in
    run_non_atomic ?timeout client t
  end

(* ---- typed cluster helpers ---- *)

let protocol_violation cmd v =
  Connection.Error.Protocol_violation
    (Format.asprintf "%s: unexpected reply %a" cmd Resp3.pp v)

let mget_cluster ?timeout client keys =
  let b = create () in
  List.iter
    (fun k -> let _ = queue b [| "GET"; k |] in ())
    keys;
  match run ?timeout client b with
  | Error e -> Error e
  | Ok None -> Error (protocol_violation "mget_cluster" Resp3.Null)
  | Ok (Some results) ->
      let err = ref None in
      let acc = ref [] in
      List.iteri
        (fun i k ->
          match results.(i) with
          | One (Ok Resp3.Null) -> acc := (k, None) :: !acc
          | One (Ok (Resp3.Bulk_string s)) -> acc := (k, Some s) :: !acc
          | One (Ok v) ->
              if !err = None then
                err := Some (protocol_violation "GET" v)
          | One (Error e) -> if !err = None then err := Some e
          | Many _ ->
              if !err = None then
                err := Some (protocol_violation
                               "mget_cluster: unexpected fan-out" Resp3.Null))
        keys;
      (match !err with
       | Some e -> Error e
       | None -> Ok (List.rev !acc))

let mset_cluster ?timeout client kvs =
  let b = create () in
  List.iter
    (fun (k, v) -> let _ = queue b [| "SET"; k; v |] in ())
    kvs;
  match run ?timeout client b with
  | Error e -> Error e
  | Ok None -> Error (protocol_violation "mset_cluster" Resp3.Null)
  | Ok (Some results) ->
      let err = ref None in
      Array.iter
        (function
          | One (Ok _) -> ()
          | One (Error e) -> if !err = None then err := Some e
          | Many _ -> ())
        results;
      (match !err with Some e -> Error e | None -> Ok ())

let del_cluster ?timeout client keys =
  let b = create () in
  List.iter
    (fun k -> let _ = queue b [| "DEL"; k |] in ())
    keys;
  match run ?timeout client b with
  | Error e -> Error e
  | Ok None -> Error (protocol_violation "del_cluster" Resp3.Null)
  | Ok (Some results) ->
      let total = ref 0 in
      let err = ref None in
      Array.iter
        (function
          | One (Ok (Resp3.Integer n)) ->
              total := !total + Int64.to_int n
          | One (Ok v) ->
              if !err = None then
                err := Some (protocol_violation "DEL" v)
          | One (Error e) -> if !err = None then err := Some e
          | Many _ -> ())
        results;
      (match !err with Some e -> Error e | None -> Ok !total)
