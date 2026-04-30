(* Pure-OCaml AWS Signature Version 4 for ElastiCache IAM.

   References:
   - https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html
   - https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/auth-iam.html

   Verified byte-exact against AWS's published signing-key vector;
   see [test/test_iam_sigv4.ml]. *)

let hex_sha256 s =
  Digestif.SHA256.digest_string s |> Digestif.SHA256.to_hex

let hmac_sha256 ~key msg =
  Digestif.SHA256.hmac_string ~key msg
  |> Digestif.SHA256.to_raw_string

let hex_of_string s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter
    (fun c -> Buffer.add_string buf (Printf.sprintf "%02x" (Char.code c)))
    s;
  Buffer.contents buf

let derive_signing_key ~secret_access_key ~date ~region ~service =
  let k_date = hmac_sha256 ~key:("AWS4" ^ secret_access_key) date in
  let k_region = hmac_sha256 ~key:k_date region in
  let k_service = hmac_sha256 ~key:k_region service in
  hmac_sha256 ~key:k_service "aws4_request"

(* RFC 3986 "unreserved": A-Z / a-z / 0-9 / - . _ ~ . Nothing else
   is safe to leave un-encoded inside a SigV4 canonical query
   component. [reserved = true] additionally keeps the path
   separator ['/'] literal — used for encoding URI paths, never
   for encoding values or keys. *)
let percent_encode ~reserved s =
  let buf = Buffer.create (String.length s) in
  String.iter
    (fun c ->
      let code = Char.code c in
      let unreserved =
        (code >= 0x30 && code <= 0x39)    (* 0-9 *)
        || (code >= 0x41 && code <= 0x5a) (* A-Z *)
        || (code >= 0x61 && code <= 0x7a) (* a-z *)
        || c = '-' || c = '.' || c = '_' || c = '~'
      in
      let keep_as_path_sep = reserved && c = '/' in
      if unreserved || keep_as_path_sep then Buffer.add_char buf c
      else Buffer.add_string buf (Printf.sprintf "%%%02X" code))
    s;
  Buffer.contents buf

(* Compare two (already-encoded) (key, value) pairs lexicographically
   by key then value — the byte-level String.compare does exactly this
   and matches what AWS's test vectors expect. *)
let compare_pair (k1, v1) (k2, v2) =
  match String.compare k1 k2 with
  | 0 -> String.compare v1 v2
  | c -> c

let canonical_query_string params =
  let encoded =
    List.map
      (fun (k, v) ->
        percent_encode ~reserved:false k,
        percent_encode ~reserved:false v)
      params
  in
  let sorted = List.sort compare_pair encoded in
  String.concat "&"
    (List.map (fun (k, v) -> k ^ "=" ^ v) sorted)

(* YYYYMMDD and YYYYMMDD'T'HHMMSS'Z' (ISO 8601 basic format, UTC). *)
let amz_timestamps now =
  let tm = Unix.gmtime now in
  let date =
    Printf.sprintf "%04d%02d%02d"
      (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday
  in
  let timestamp =
    Printf.sprintf "%sT%02d%02d%02dZ"
      date tm.tm_hour tm.tm_min tm.tm_sec
  in
  date, timestamp

(* Breakdown of a presigned token's intermediate SigV4 strings.
   Returned by [presigned_elasticache_token_with_steps] so tests
   can pin every stage (canonical query, canonical request,
   string-to-sign, signature) against AWS's published test
   vectors. *)
type presign_steps = {
  canonical_query : string;
  canonical_request : string;
  string_to_sign : string;
  signature : string;
  token : string;
}

let presigned_elasticache_token_with_steps
    ~credentials ~region ~cluster_id ~user_id ~now =
  let cluster_id = String.lowercase_ascii cluster_id in
  let service = "elasticache" in
  let date, timestamp = amz_timestamps now in
  let scope =
    Printf.sprintf "%s/%s/%s/aws4_request" date region service
  in
  let credential =
    Printf.sprintf "%s/%s" credentials.Iam_credentials.access_key_id scope
  in
  (* Query parameters that will be signed AND appear in the
     final URL, EXCEPT the signature itself which is appended
     after signing. [X-Amz-Security-Token] is included when
     session credentials are in use (STS, IRSA, etc.). *)
  let base_params =
    [ "Action", "connect";
      "User", user_id;
      "X-Amz-Algorithm", "AWS4-HMAC-SHA256";
      "X-Amz-Credential", credential;
      "X-Amz-Date", timestamp;
      "X-Amz-Expires", "900";
      "X-Amz-SignedHeaders", "host";
    ]
  in
  let params =
    match credentials.session_token with
    | None -> base_params
    | Some t -> ("X-Amz-Security-Token", t) :: base_params
  in
  let canonical_query = canonical_query_string params in
  (* Canonical request:
       method \n
       canonical_uri \n
       canonical_query \n
       canonical_headers \n \n
       signed_headers \n
       hashed_payload
     For a presigned GET with a signed 'host' header only, the
     canonical URI is "/" and the hashed payload is the SHA-256
     of the empty string (AWS UNSIGNED-PAYLOAD is not used
     here — presigned URLs sign the empty body). *)
  let empty_hash = hex_sha256 "" in
  let canonical_request =
    String.concat "\n"
      [ "GET";
        "/";
        canonical_query;
        "host:" ^ cluster_id;
        "";
        "host";
        empty_hash;
      ]
  in
  let string_to_sign =
    String.concat "\n"
      [ "AWS4-HMAC-SHA256";
        timestamp;
        scope;
        hex_sha256 canonical_request;
      ]
  in
  let signing_key =
    derive_signing_key
      ~secret_access_key:credentials.Iam_credentials.secret_access_key
      ~date ~region ~service
  in
  let signature =
    hex_of_string (hmac_sha256 ~key:signing_key string_to_sign)
  in
  (* Token is the presigned URL minus the [http://] scheme:
       <cluster-id>/?<query>&X-Amz-Signature=<sig>
     ElastiCache strips and interprets this as-is. *)
  let token =
    Printf.sprintf "%s/?%s&X-Amz-Signature=%s"
      cluster_id canonical_query signature
  in
  { canonical_query; canonical_request; string_to_sign;
    signature; token }

let presigned_elasticache_token
    ~credentials ~region ~cluster_id ~user_id ~now =
  (presigned_elasticache_token_with_steps
     ~credentials ~region ~cluster_id ~user_id ~now).token
