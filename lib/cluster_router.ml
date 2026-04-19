module Config = struct
  type t = {
    seeds : (string * int) list;
    connection : Connection.Config.t;
    agreement_ratio : float;
    min_nodes_for_quorum : int;
    max_redirects : int;
    prefer_hostname : bool;
  }

  let default ~seeds = {
    seeds;
    connection = Connection.Config.default;
    agreement_ratio = 0.2;
    min_nodes_for_quorum = 3;
    max_redirects = 5;
    prefer_hostname = false;
  }
end

let address_of_node ~prefer_hostname (node : Topology.Node.t) =
  let non_empty = function
    | Some "" | Some "?" | None -> None
    | Some s -> Some s
  in
  let from_hostname = if prefer_hostname then non_empty node.hostname else None in
  match from_hostname with
  | Some h -> Some h
  | None ->
      (match non_empty node.ip with
       | Some ip -> Some ip
       | None -> non_empty node.endpoint)

let port_of_node ~tls (node : Topology.Node.t) =
  if tls then
    match node.tls_port with
    | Some p -> Some p
    | None -> node.port
  else
    match node.port with
    | Some p -> Some p
    | None -> node.tls_port

let pick_node_by_read_from (rf : Router.Read_from.t) (shard : Topology.Shard.t) =
  let find_az az nodes =
    List.find_opt
      (fun (n : Topology.Node.t) -> n.availability_zone = Some az)
      nodes
  in
  match rf with
  | Router.Read_from.Primary -> shard.primary
  | Router.Read_from.Prefer_replica ->
      (match shard.replicas with
       | [] -> shard.primary
       | r :: _ -> r)
  | Router.Read_from.Az_affinity { az } ->
      (match find_az az shard.replicas with
       | Some r -> r
       | None -> shard.primary)
  | Router.Read_from.Az_affinity_replicas_and_primary { az } ->
      let all_nodes = shard.primary :: shard.replicas in
      (match find_az az all_nodes with
       | Some n -> n
       | None -> shard.primary)

let build_pool ~sw ~net ~clock ?domain_mgr ~connection_config ~prefer_hostname
    topology =
  let pool = Node_pool.create () in
  let tls_enabled = connection_config.Connection.Config.tls <> None in
  List.iter
    (fun (node : Topology.Node.t) ->
      if node.health = Topology.Node.Online then begin
        match
          address_of_node ~prefer_hostname node,
          port_of_node ~tls:tls_enabled node
        with
        | Some host, Some port ->
            (try
               let conn =
                 Connection.connect ~sw ~net ~clock ?domain_mgr
                   ~config:connection_config ~host ~port ()
               in
               Node_pool.add pool node.id conn
             with _ -> ())
        | _ -> ()
      end)
    (Topology.all_nodes topology);
  pool

let err_protocol fmt =
  Format.kasprintf
    (fun s -> Error (Connection.Error.Protocol_violation s))
    fmt

let err_terminal fmt =
  Format.kasprintf
    (fun s -> Error (Connection.Error.Terminal s))
    fmt

(* Execute [args] once against [conn]. Used for both the initial dispatch
   and retries after a redirect. *)
let send_once ?timeout conn args = Connection.request ?timeout conn args

let handle_redirect ~pool ~topology_ref ~max_redirects
    ?timeout first_result args =
  let rec loop attempt result =
    match result with
    | Ok _ -> result
    | Error (Connection.Error.Server_error ve) when attempt < max_redirects ->
        (match Redirect.of_valkey_error ve with
         | None -> result
         | Some { kind; host; port; _ } ->
             (match
                Topology.find_node_by_address !topology_ref ~host ~port
              with
              | None ->
                  (* Unknown address — future work: trigger topology
                     refresh, retry. For now surface the error. *)
                  result
              | Some node ->
                  (match Node_pool.get pool node.id with
                   | None -> result
                   | Some conn ->
                       (* For ASK, send ASKING before the original. For
                          MOVED, just retry on the new node. *)
                       (match kind with
                        | Redirect.Ask ->
                            (match send_once ?timeout conn [| "ASKING" |] with
                             | Ok _ -> ()
                             | Error _ -> ());
                        | Redirect.Moved -> ());
                       let next = send_once ?timeout conn args in
                       loop (attempt + 1) next)))
    | Error _ -> result
  in
  loop 0 first_result

let make_exec ~pool ~topology_ref ~max_redirects ?timeout
    (target : Router.Target.t) (rf : Router.Read_from.t)
    (args : string array) =
  let topology = !topology_ref in
  let dispatch_initial () =
    match target with
    | Router.Target.By_slot slot ->
        (match Topology.shard_for_slot topology slot with
         | None -> err_protocol "no shard owns slot %d" slot
         | Some shard ->
             let node = pick_node_by_read_from rf shard in
             (match Node_pool.get pool node.id with
              | None ->
                  err_terminal "no live connection for node %s" node.id
              | Some conn -> send_once ?timeout conn args))
    | Router.Target.By_node node_id ->
        (match Node_pool.get pool node_id with
         | None -> err_terminal "unknown node %s" node_id
         | Some conn -> send_once ?timeout conn args)
    | Router.Target.Random ->
        (match Node_pool.connections pool with
         | [] -> err_terminal "cluster has no live connections"
         | c :: _ -> send_once ?timeout c args)
    | Router.Target.All_nodes | Router.Target.All_primaries ->
        err_terminal "cluster router: fan-out targets not yet implemented"
    | Router.Target.By_channel _ ->
        err_terminal "cluster router: sharded pub/sub not yet implemented"
  in
  handle_redirect ~pool ~topology_ref ~max_redirects ?timeout
    (dispatch_initial ()) args

let from_pool_and_topology ?(max_redirects = 5) ~pool ~topology () =
  let topology_ref = ref topology in
  let exec ?timeout target rf args =
    make_exec ~pool ~topology_ref ~max_redirects ?timeout target rf args
  in
  let close () = Node_pool.close_all pool in
  let primary () =
    match Node_pool.connections pool with [] -> None | c :: _ -> Some c
  in
  Router.make ~exec ~close ~primary

let create ~sw ~net ~clock ?domain_mgr ~config:(cfg : Config.t) () =
  match
    Discovery.discover_from_seeds
      ~sw ~net ~clock ?domain_mgr
      ~connection_config:cfg.connection
      ~agreement_ratio:cfg.agreement_ratio
      ~min_nodes_for_quorum:cfg.min_nodes_for_quorum
      ~seeds:cfg.seeds ()
  with
  | Error e -> Error e
  | Ok topology ->
      let pool =
        build_pool ~sw ~net ~clock ?domain_mgr
          ~connection_config:cfg.connection
          ~prefer_hostname:cfg.prefer_hostname
          topology
      in
      Ok (from_pool_and_topology ~max_redirects:cfg.max_redirects
            ~pool ~topology ())
