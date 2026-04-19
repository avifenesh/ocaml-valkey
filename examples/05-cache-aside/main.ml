(* Read-through cache layer with hash field TTL.

   Pattern: each cached entity (a user) is one hash key. Within
   that hash, each field is a cached attribute with its own TTL.

     user:42     hash
       name           "ada"             persistent (no TTL)
       avatar_url     "..."             5 min TTL  (image cache)
       seen_now       "1715..."         30 s TTL   (presence)

   The advantage over per-field keys: O(1) HGETALL fetches the
   whole entity (skip stale fields by checking which still exist),
   and rotating one field's TTL doesn't disturb the others.

   Hash field TTL is Valkey 9+. Older servers reply with an error
   on HEXPIRE. *)

module C = Valkey.Client
module E = Valkey.Connection.Error

(* Pretend "database" — slow function that returns the freshly
   computed value. *)
let load_from_db ~field ~user =
  Printf.printf "  [db] computing %s for %s\n%!" field user;
  Unix.sleepf 0.05;
  match field with
  | "name" -> "ada"
  | "avatar_url" -> Printf.sprintf "https://avatars.example/%s.png" user
  | "seen_now" -> string_of_int (int_of_float (Unix.gettimeofday ()))
  | _ -> ""

(* TTL policy per field. None = persistent. *)
let ttl_for = function
  | "avatar_url" -> Some 300       (* 5 minutes *)
  | "seen_now"   -> Some 30        (* 30 seconds *)
  | _ -> None

let cache_key user = Printf.sprintf "user:%s" user

(* Read-through. Returns (value, hit?). *)
let read_through ~client ~user ~field =
  let key = cache_key user in
  match C.hget client key field with
  | Ok (Some v) -> (v, true)
  | Ok None | Error _ ->
      let v = load_from_db ~field ~user in
      let _ = C.hset client key [ field, v ] in
      (match ttl_for field with
       | Some s ->
           let _ = C.hexpire client key ~seconds:s [ field ] in ()
       | None -> ());
      (v, false)

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    C.connect ~sw
      ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~host:"localhost" ~port:6379 ()
  in

  (* Wipe so the demo is reproducible. *)
  let _ = C.del client [ cache_key "42" ] in

  let probe field =
    let (v, hit) = read_through ~client ~user:"42" ~field in
    Printf.printf "%-12s %s   (%s)\n"
      field v (if hit then "HIT" else "MISS")
  in

  print_endline "first round (all misses, populates the cache):";
  probe "name";
  probe "avatar_url";
  probe "seen_now";

  print_endline "\nsecond round (everything hits):";
  probe "name";
  probe "avatar_url";
  probe "seen_now";

  print_endline "\nfields and their remaining TTLs (-1 = no expiry, -2 = missing):";
  (match
     C.httl client (cache_key "42")
       [ "name"; "avatar_url"; "seen_now" ]
   with
   | Ok states ->
       List.iter2
         (fun field s ->
           let txt =
             match s with
             | C.Persistent -> "persistent"
             | C.Absent -> "missing"
             | C.Expires_in s -> Printf.sprintf "expires in %d s" s
           in
           Printf.printf "  %-12s %s\n" field txt)
         [ "name"; "avatar_url"; "seen_now" ] states
   | Error e -> Format.eprintf "HTTL: %a@." E.pp e);

  C.close client
