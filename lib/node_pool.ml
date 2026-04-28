(* Bundle-per-node pool. Read path is lock-free via
   [Atomic.t] snapshot of the hashtable; writes (topology diff)
   take a serialising mutex and publish a fresh Hashtbl.

   The hashtable itself is mutable, but we never mutate a
   published one — every write allocates a copy, mutates the
   copy, and [Atomic.set]s the new snapshot. Readers capturing
   a prior snapshot see a stable, immutable-in-practice view
   even if a topology diff races.

   At 145 k ops/s observed on [core_N1_plain], the previous
   mutex-on-every-pick cost 4-7 % of a core on the read path;
   [Atomic.get] is a single load. *)

type t = {
  snapshot : (string, Connection.t array) Hashtbl.t Atomic.t;
  write_mutex : Eio.Mutex.t;
  (* Serialises writers so concurrent [add_bundle]/[remove_bundle]
     don't both copy the same prior snapshot and each install a
     version missing the other's change. *)
  rr_cursor : int Atomic.t;
  (* Pool-wide round-robin counter. Single atomic keeps the
     distribution fair across bundle indices regardless of which
     [node_id] each caller lands on; a per-node counter would
     starve low-traffic nodes from ever rotating. *)
}

let create () =
  { snapshot = Atomic.make (Hashtbl.create 16);
    write_mutex = Eio.Mutex.create ();
    rr_cursor = Atomic.make 0 }

let validate_bundle_size n =
  if n < 1 then
    invalid_arg
      (Printf.sprintf
         "connections_per_node must be >= 1 (got %d)" n)

(* Copy-on-write: clone the current snapshot, apply [f] to the
   clone, publish. Serialised under [write_mutex] so writers
   don't clobber each other's work.

   [protect:true] on the write-path mutex: if a writer fiber
   is cancelled mid-copy we must not leak a half-built table. *)
let update t f =
  Eio.Mutex.use_rw ~protect:true t.write_mutex (fun () ->
      let cur = Atomic.get t.snapshot in
      let next = Hashtbl.copy cur in
      let r = f next in
      Atomic.set t.snapshot next;
      r)

let add_bundle t ~node_id conns =
  if Array.length conns = 0 then
    invalid_arg "Node_pool.add_bundle: empty connection bundle";
  update t (fun tbl -> Hashtbl.replace tbl node_id conns)

let remove_bundle t ~node_id =
  update t (fun tbl ->
      match Hashtbl.find_opt tbl node_id with
      | None -> None
      | Some arr -> Hashtbl.remove tbl node_id; Some arr)

let pick t ~node_id =
  match Hashtbl.find_opt (Atomic.get t.snapshot) node_id with
  | None -> None
  | Some arr ->
      let n = Array.length arr in
      if n = 0 then None
      else
        let c = Atomic.fetch_and_add t.rr_cursor 1 in
        (* [c] can go negative once it wraps past max_int
           (~150 000 years at 1 M ops/s, so never in practice,
           but [Atomic.fetch_and_add] doesn't overflow-check).
           Double-mod keeps the index in [0, n). *)
        let i = ((c mod n) + n) mod n in
        Some arr.(i)

let pick_for_slot t ~node_id ~slot =
  (* Callers resolve [slot] via [Topology.shard_for_slot],
     [Redirect.slot], or CRC16 — all guaranteed in [0, 16383].
     A negative slot is a programmer bug; raise loudly rather than
     silently clamping to [bundle.(0)] and masking the regression. *)
  if slot < 0 then
    invalid_arg
      (Printf.sprintf "Node_pool.pick_for_slot: slot must be >= 0 (got %d)"
         slot);
  match Hashtbl.find_opt (Atomic.get t.snapshot) node_id with
  | None -> None
  | Some arr ->
      let n = Array.length arr in
      if n = 0 then None
      else Some arr.(slot mod n)

let node_ids t =
  Hashtbl.fold (fun k _ acc -> k :: acc) (Atomic.get t.snapshot) []

let all_connections t =
  Hashtbl.fold
    (fun _ arr acc -> Array.fold_left (fun a c -> c :: a) acc arr)
    (Atomic.get t.snapshot) []

let close_all t =
  let to_close =
    update t (fun tbl ->
        let l =
          Hashtbl.fold
            (fun _ arr acc -> Array.fold_left (fun a c -> c :: a) acc arr)
            tbl []
        in
        Hashtbl.clear tbl;
        l)
  in
  List.iter
    (fun c ->
      try Connection.close c
      with Eio.Io _ | End_of_file | Invalid_argument _
         | Unix.Unix_error _ -> ())
    to_close

let size t = Hashtbl.length (Atomic.get t.snapshot)

let total_conns t =
  Hashtbl.fold (fun _ arr acc -> acc + Array.length arr)
    (Atomic.get t.snapshot) 0
