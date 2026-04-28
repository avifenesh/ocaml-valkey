type t = {
  bundles : (string, Connection.t array) Hashtbl.t;
  mutex : Eio.Mutex.t;
  rr_cursor : int Atomic.t;
  (* Pool-wide round-robin counter. Single atomic keeps the
     distribution fair across bundle indices regardless of which
     [node_id] each caller lands on; a per-node counter would
     starve low-traffic nodes from ever rotating. *)
}

let create () =
  { bundles = Hashtbl.create 16;
    mutex = Eio.Mutex.create ();
    rr_cursor = Atomic.make 0 }

let add_bundle t ~node_id conns =
  if Array.length conns = 0 then
    invalid_arg "Node_pool.add_bundle: empty connection bundle";
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.replace t.bundles node_id conns)

let remove_bundle t ~node_id =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      match Hashtbl.find_opt t.bundles node_id with
      | None -> None
      | Some arr ->
          Hashtbl.remove t.bundles node_id;
          Some arr)

let pick t ~node_id =
  (* Snapshot the bundle under the lock so the rr pick happens on
     an immutable array — no race with a concurrent add/remove. *)
  let bundle =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        Hashtbl.find_opt t.bundles node_id)
  in
  match bundle with
  | None -> None
  | Some arr ->
      let n = Array.length arr in
      if n = 0 then None
      else
        let c = Atomic.fetch_and_add t.rr_cursor 1 in
        (* [c] may go negative once it wraps past max_int; guard
           the modulo so the index stays in [0, n). *)
        let i = ((c mod n) + n) mod n in
        Some arr.(i)

let pick_for_slot t ~node_id ~slot =
  let bundle =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        Hashtbl.find_opt t.bundles node_id)
  in
  match bundle with
  | None -> None
  | Some arr ->
      let n = Array.length arr in
      if n = 0 then None
      else
        let s = if slot < 0 then 0 else slot in
        Some arr.(s mod n)

let node_ids t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.fold (fun k _ acc -> k :: acc) t.bundles [])

let all_connections t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.fold
        (fun _ arr acc -> Array.fold_left (fun a c -> c :: a) acc arr)
        t.bundles [])

let close_all t =
  let to_close =
    Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
        let l =
          Hashtbl.fold
            (fun _ arr acc -> Array.fold_left (fun a c -> c :: a) acc arr)
            t.bundles []
        in
        Hashtbl.clear t.bundles;
        l)
  in
  List.iter
    (fun c ->
      try Connection.close c
      with Eio.Io _ | End_of_file | Invalid_argument _
         | Unix.Unix_error _ -> ())
    to_close

let size t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.length t.bundles)

let total_conns t =
  Eio.Mutex.use_rw ~protect:true t.mutex (fun () ->
      Hashtbl.fold (fun _ arr acc -> acc + Array.length arr) t.bundles 0)
