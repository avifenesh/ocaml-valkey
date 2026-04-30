type t = {
  access_key_id : string;
  secret_access_key : string;
  session_token : string option;
}

let make ~access_key_id ~secret_access_key ?session_token () =
  { access_key_id; secret_access_key; session_token }

let getenv_opt name =
  match Sys.getenv_opt name with
  | Some "" | None -> None
  | Some v -> Some v

let of_env () =
  match
    getenv_opt "AWS_ACCESS_KEY_ID",
    getenv_opt "AWS_SECRET_ACCESS_KEY"
  with
  | None, _ -> Error "AWS_ACCESS_KEY_ID not set"
  | _, None -> Error "AWS_SECRET_ACCESS_KEY not set"
  | Some k, Some s ->
      Ok { access_key_id = k;
           secret_access_key = s;
           session_token = getenv_opt "AWS_SESSION_TOKEN" }
