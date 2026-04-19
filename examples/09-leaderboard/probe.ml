(* Throwaway: print the raw RESP3 reply for ZRANGE WITHSCORES so
   we can write the right decoder. *)

module C = Valkey.Client

let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let client =
    C.connect ~sw
      ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
      ~host:"localhost" ~port:6379 ()
  in
  let _ = C.del client [ "lprobe" ] in
  let _ =
    C.custom client [| "ZADD"; "lprobe"; "100"; "ada"; "75"; "bob" |]
  in
  let r =
    C.custom client
      [| "ZRANGE"; "lprobe"; "0"; "-1"; "REV"; "WITHSCORES" |]
  in
  (match r with
   | Ok v -> Format.printf "raw: %a@." Valkey.Resp3.pp v
   | Error e -> Format.eprintf "err: %a@." Valkey.Connection.Error.pp e);
  C.close client
