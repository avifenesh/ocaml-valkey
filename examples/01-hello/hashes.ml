(* Hashes + per-field TTL (Valkey 9+).

   HSET / HGET / HGETALL are the obvious bits. The interesting part
   is per-field TTL: each field in a hash can have its own expiry,
   not just the whole key. *)

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

  let key = "user:42" in

  (* Bulk set multiple fields. *)
  (match
     C.hset client key
       [ "name", "ada"; "email", "ada@example.com"; "country", "uk" ]
   with
   | Ok n -> Printf.printf "HSET added %d new fields\n" n
   | Error e -> Format.eprintf "HSET: %a@." E.pp e);

  (* Read individual fields. *)
  (match C.hget client key "email" with
   | Ok (Some v) -> Printf.printf "email -> %s\n" v
   | Ok None -> print_endline "email -> (missing field)"
   | Error e -> Format.eprintf "HGET: %a@." E.pp e);

  (* Read everything as an assoc list. *)
  (match C.hgetall client key with
   | Ok kvs ->
       List.iter (fun (k, v) -> Printf.printf "  %s = %s\n" k v) kvs
   | Error e -> Format.eprintf "HGETALL: %a@." E.pp e);

  (* Per-field TTL: country expires in 60s, others stay forever.
     Returns one [field_ttl_set] per field — useful when applying
     conditions or batching. *)
  (match
     C.hexpire client key ~seconds:60 [ "country" ]
   with
   | Ok statuses ->
       List.iteri
         (fun i s ->
           let what =
             match s with
             | C.Hfield_ttl_set -> "set"
             | C.Hfield_missing -> "missing"
             | C.Hfield_condition_failed -> "blocked"
             | C.Hfield_expired_now -> "expired immediately"
           in
           Printf.printf "  field[%d]: %s\n" i what)
         statuses
   | Error e -> Format.eprintf "HEXPIRE: %a@." E.pp e);

  C.close client
