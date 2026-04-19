type kind = Moved | Ask

type t = {
  kind : kind;
  slot : int;
  host : string;
  port : int;
}

let kind_of_code = function
  | "MOVED" -> Some Moved
  | "ASK" -> Some Ask
  | _ -> None

let split_last_colon s =
  match String.rindex_opt s ':' with
  | None -> None
  | Some i ->
      Some (String.sub s 0 i,
            String.sub s (i + 1) (String.length s - i - 1))

let of_valkey_error (ve : Valkey_error.t) =
  match kind_of_code ve.code with
  | None -> None
  | Some kind ->
      (* message is "<slot> <host>:<port>" *)
      (match String.index_opt ve.message ' ' with
       | None -> None
       | Some sp ->
           let slot_s = String.sub ve.message 0 sp in
           let rest = String.sub ve.message (sp + 1)
                        (String.length ve.message - sp - 1) in
           (match int_of_string_opt slot_s, split_last_colon rest with
            | Some slot, Some (host, port_s) ->
                (match int_of_string_opt port_s with
                 | Some port -> Some { kind; slot; host; port }
                 | None -> None)
            | _ -> None))
