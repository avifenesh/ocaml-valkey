(* Property tests for routing. Requires the docker-compose cluster.

   Three properties:

   1. Random-key dispatch: no matter what key we pick, a round-trip
      SET → GET → DEL must succeed. A routing bug manifests as an
      error bubbling up from [Cluster_router.exec] (MOVED that
      exhausts the retry budget, connection errors, etc.). 500
      randomised keys give broad slot coverage.

   2. Slot coverage invariant: every one of the 16384 slots has a
      live primary endpoint in the router's topology. If any slot
      is unowned, single-key commands routed to that slot would
      have nowhere to go.

   3. Read_from is respected: issuing a readonly command with
      [By_slot s] + [Prefer_replica] reaches a replica, while the
      same call with [Primary] reaches the primary. We probe via
      `CLUSTER MYID`, which returns the node ID of whichever node
      served the request. *)

module C = Valkey.Client
module CR = Valkey.Cluster_router
module Conn = Valkey.Connection
module R = Valkey.Router

let seeds = Test_support.seeds
let force_skip = Test_support.force_skip
let cluster_reachable = Test_support.cluster_reachable

let with_cluster_router f =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let config =
    { (CR.Config.default ~seeds) with prefer_hostname = true }
  in
  match CR.create ~sw ~net ~clock ~config () with
  | Error m -> Alcotest.failf "Cluster_router.create: %s" m
  | Ok router ->
      let client = C.from_router ~config:C.Config.default router in
      let finalize () = C.close client in
      (try f ~router ~client; finalize ()
       with e -> finalize (); raise e)

let err_pp = Conn.Error.pp

(* ---------- property 1: random-key dispatch ---------- *)

let rand_key rng i =
  let n = 4 + Random.State.int rng 16 in
  let body =
    String.init n (fun _ ->
        let c = Random.State.int rng 94 + 32 in
        (* Avoid whitespace and control characters in the key so
           the test is portable; still covers the full slot space. *)
        Char.chr (if c = 0x20 then 0x21 else c))
  in
  Printf.sprintf "prop:rand:%d:%s" i body

let test_random_key_roundtrip () =
  with_cluster_router @@ fun ~router:_ ~client ->
  let rng = Random.State.make [| 0xDEAD; 0xBEEF |] in
  let keys = List.init 500 (rand_key rng) in
  List.iter
    (fun k ->
      match C.set client k "v" with
      | Ok _ -> ()
      | Error e -> Alcotest.failf "SET %S: %a" k err_pp e)
    keys;
  List.iter
    (fun k ->
      match C.get client k with
      | Ok (Some "v") -> ()
      | Ok (Some other) ->
          Alcotest.failf "GET %S returned %S, expected \"v\"" k other
      | Ok None ->
          Alcotest.failf "GET %S returned None after SET" k
      | Error e -> Alcotest.failf "GET %S: %a" k err_pp e)
    keys;
  (* Delete in small batches so the per-call slot is single and
     CROSSSLOT doesn't fire. *)
  List.iter
    (fun k ->
      match C.del client [ k ] with
      | Ok _ -> ()
      | Error e -> Alcotest.failf "DEL %S: %a" k err_pp e)
    keys

(* ---------- property 2: slot coverage ---------- *)

let test_slot_coverage_full () =
  with_cluster_router @@ fun ~router ~client:_ ->
  let unowned = ref [] in
  for s = 0 to 16383 do
    match R.endpoint_for_slot router s with
    | Some _ -> ()
    | None -> unowned := s :: !unowned
  done;
  match !unowned with
  | [] -> ()
  | xs ->
      let first_few =
        List.filteri (fun i _ -> i < 10) (List.rev xs)
      in
      Alcotest.failf
        "%d slots unowned. First: %s"
        (List.length xs)
        (String.concat ", "
           (List.map string_of_int first_few))

(* ---------- property 3: Read_from respected ---------- *)

(* Call CLUSTER MYID via a direct [custom ~target ~read_from] path.
   The reply is the ID of whichever node served it — which is the
   node the router chose. *)
let cluster_myid ~client ~slot ~read_from =
  match
    C.custom ~target:(R.Target.By_slot slot) ~read_from client
      [| "CLUSTER"; "MYID" |]
  with
  | Ok (Valkey.Resp3.Bulk_string id)
  | Ok (Valkey.Resp3.Simple_string id) -> id
  | Ok other ->
      Alcotest.failf
        "CLUSTER MYID returned %a, expected bulk/simple string"
        Valkey.Resp3.pp other
  | Error e ->
      Alcotest.failf "CLUSTER MYID: %a" err_pp e

let test_read_from_respected () =
  with_cluster_router @@ fun ~router ~client ->
  (* Sample a handful of slots, one per primary shard. Cluster has
     3 primaries, so slots 0 / 5500 / 11000 land on different ones
     in the default Valkey 9 layout. *)
  let sample_slots = [ 0; 5500; 11000 ] in
  (* Pre-flight: confirm the topology has replicas. Without
     replicas, Prefer_replica silently falls back to the primary
     and the property is vacuous — mark as skip rather than fail. *)
  let has_replicas =
    try
      match
        C.custom ~target:R.Target.Random client [| "CLUSTER"; "NODES" |]
      with
      | Ok (Valkey.Resp3.Bulk_string s) ->
          (* Each replica line contains " slave " or " replica ". *)
          let has_needle needle =
            let ls = String.length s and ln = String.length needle in
            let rec loop i =
              if i + ln > ls then false
              else if String.sub s i ln = needle then true
              else loop (i + 1)
            in
            loop 0
          in
          has_needle " slave " || has_needle " replica "
      | _ -> false
    with _ -> false
  in
  if not has_replicas then
    (* Don't fail — just make the skip visible. *)
    print_endline
      "[skip] cluster has no replicas; Read_from property vacuous"
  else
    List.iter
      (fun slot ->
        let primary_id =
          cluster_myid ~client ~slot ~read_from:R.Read_from.Primary
        in
        (* Run Prefer_replica a few times; at least one call should
           hit a replica. A single call might get unlucky if the
           pool randomises. *)
        let replica_ids =
          List.init 6 (fun _ ->
              cluster_myid ~client ~slot
                ~read_from:R.Read_from.Prefer_replica)
        in
        if List.for_all (String.equal primary_id) replica_ids then
          Alcotest.failf
            "Prefer_replica for slot %d always returned the \
             primary %s across 6 calls; Read_from ignored?"
            slot primary_id;
        ignore router)
      sample_slots

(* ---------- registration ---------- *)

let skip_placeholder name () =
  Printf.printf
    "[skipped] %s (cluster unreachable; docker-compose.cluster.yml)\n%!"
    name

let tests =
  let reachable = cluster_reachable () in
  let tc name f =
    if reachable then Alcotest.test_case name `Quick f
    else Alcotest.test_case name `Quick (skip_placeholder name)
  in
  [ tc "500 random keys: SET/GET/DEL round-trip"
      test_random_key_roundtrip;
    tc "slot coverage: every slot 0..16383 has an endpoint"
      test_slot_coverage_full;
    tc "Read_from.Prefer_replica routes to a replica"
      test_read_from_respected;
  ]
