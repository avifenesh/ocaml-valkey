let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let conn =
    Valkey.Connection.connect ~sw ~net ~clock ~host:"localhost" ~port:6379 ()
  in
  (match Valkey.Connection.request conn [| "PING" |] with
   | Ok v -> Format.printf "PING -> %a@." Valkey.Resp3.pp v
   | Error e -> Format.printf "PING ERR %a@." Valkey.Connection.Error.pp e);
  (match Valkey.Connection.request conn [| "PING"; "hello from ocaml" |] with
   | Ok v -> Format.printf "PING msg -> %a@." Valkey.Resp3.pp v
   | Error e -> Format.printf "PING msg ERR %a@." Valkey.Connection.Error.pp e);
  Format.printf "AZ: %s@."
    (match Valkey.Connection.availability_zone conn with
     | Some z -> z
     | None -> "<none>");
  Valkey.Connection.close conn
