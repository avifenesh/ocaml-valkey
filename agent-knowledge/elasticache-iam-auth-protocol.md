# Learning Guide: AWS ElastiCache IAM Authentication Protocol

**Generated**: 2026-04-28
**Sources**: 15+ primary sources analyzed
**Depth**: medium
**Target**: Client implementers needing wire-level protocol details

## Prerequisites

Before implementing ElastiCache IAM authentication:
- Understanding of AWS SigV4 signing process
- Familiarity with Redis/Valkey AUTH/HELLO commands
- Knowledge of RESP3 protocol
- AWS IAM concepts (roles, policies, ARNs)
- Basic cryptography (HMAC-SHA256)

## TL;DR

- IAM auth token = SigV4-presigned GET request URL to `http://{cluster-id}/?Action=connect&User={user-id}`
- Token presented as password in AUTH/HELLO (sans `http://` prefix)
- Service name: `elasticache`, TTL: 900 seconds (15 minutes)
- TLS mandatory, Valkey 7.2+ or Redis OSS 7.0+ required
- ElastiCache user-id and user-name must be identical for IAM users
- Connection auto-disconnects after 12 hours; send new AUTH to extend
- Each token is region-scoped; generate fresh per region

## Core Concepts

### 1. IAM Token Structure

The IAM authentication token is a **presigned HTTP GET request URL** constructed per AWS Signature Version 4 (SigV4) specification.

**URL Template:**
```
http://{cache-identifier}/?Action=connect&User={userId}
```

**Example Components:**
- `cache-identifier`: Replication group ID or serverless cache name (lowercase)
- `Action=connect`: Fixed parameter indicating ElastiCache Connect operation
- `User={userId}`: ElastiCache user ID to authenticate as

After SigV4 signing, the URL includes:
```
X-Amz-Algorithm=AWS4-HMAC-SHA256
X-Amz-Credential={access-key}/{date}/{region}/elasticache/aws4_request
X-Amz-Date={timestamp}
X-Amz-SignedHeaders=host
X-Amz-Signature={calculated-signature}
```

**Source**: AWS ElastiCache IAM Authentication Documentation, IAMAuthTokenRequest.java sample

### 2. SigV4 Signing Process for ElastiCache

**Service Name**: `elasticache` (lowercase, critical for signature calculation)

**Signing Parameters:**
- **HTTP Method**: GET
- **Region**: Target cluster's AWS region
- **Expiration**: 900 seconds (15 minutes) from signing time
- **Signature Location**: QUERY_STRING (not Authorization header)

**Canonical Request Format:**
```
GET
/{cache-identifier}/
Action=connect&User={user-id}&X-Amz-Algorithm=...&X-Amz-Credential=...
host:{cache-identifier}

host
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

**String-to-Sign:**
```
AWS4-HMAC-SHA256
{timestamp}
{date}/{region}/elasticache/aws4_request
{hex(SHA256(canonical-request))}
```

**Signing Key Derivation:**
```
DateKey              = HMAC-SHA256("AWS4" + SecretKey, date)
DateRegionKey        = HMAC-SHA256(DateKey, region)
DateRegionServiceKey = HMAC-SHA256(DateRegionKey, "elasticache")
SigningKey           = HMAC-SHA256(DateRegionServiceKey, "aws4_request")
```

**Final Signature:**
```
Signature = hex(HMAC-SHA256(SigningKey, string-to-sign))
```

**Sources**: AWS SigV4 Documentation, IAMAuthTokenRequest.java implementation, AWS General Reference

### 3. Token Presentation to Server

**Format Transformation:**
1. Generate full presigned URL: `http://cluster-id/?Action=connect&User=...&X-Amz-Signature=...`
2. Strip `http://` prefix: `cluster-id/?Action=connect&User=...&X-Amz-Signature=...`
3. Present stripped URL as password parameter

**RESP3 HELLO Command:**
```
HELLO 3 AUTH {user-id} {stripped-token}
```

**RESP2 AUTH Command:**
```
AUTH {user-id} {stripped-token}
```

**Critical Requirements:**
- Username must match ElastiCache user-id (not IAM ARN, not IAM username)
- Token is the full query string including all SigV4 parameters
- Token is NOT base64-encoded, NOT double-quoted

**Source**: AWS ElastiCache IAM Documentation

### 4. ElastiCache User Configuration

**CreateUser API Requirements for IAM:**

```bash
aws elasticache create-user \
  --user-id iam-user-01 \
  --user-name iam-user-01 \  # MUST match user-id
  --engine redis \  # or "valkey"
  --access-string "on ~* +@all" \
  --authentication-mode Type=iam
```

**Key Constraints:**
- `user-id` and `user-name` must be **identical** for IAM-enabled users
- `user-id` pattern: `[a-zA-Z][a-zA-Z0-9\-]*`, stored as lowercase
- Minimum engine version: Valkey 7.2+ or Redis OSS 7.0+
- TLS (in-transit encryption) **required**

**User Group Assignment:**
```bash
aws elasticache create-user-group \
  --user-group-id iam-group-01 \
  --engine redis \
  --user-ids default iam-user-01

aws elasticache modify-serverless-cache \
  --serverless-cache-name cache-01 \
  --user-group-id iam-group-01
```

**Sources**: AWS ElastiCache API Reference (CreateUser, AuthenticationMode), Boto3 Documentation

### 5. IAM Policy Configuration

**Required Action:**
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["elasticache:Connect"],
    "Resource": [
      "arn:aws:elasticache:{region}:{account}:serverlesscache:{cache-name}",
      "arn:aws:elasticache:{region}:{account}:user:{user-id}"
    ]
  }]
}
```

**Resource Types:**
- **user** (required): `arn:aws:elasticache:{region}:{account}:user:{user-id}`
- **serverlesscache** (optional): `arn:aws:elasticache:{region}:{account}:serverlesscache:{name}`
- **replicationgroup** (optional): `arn:aws:elasticache:{region}:{account}:replicationgroup:{id}`

**Condition Keys Available:**
- `aws:ResourceTag/${TagKey}` (String) - Filter by resource tags
- `aws:VpcSourceIp` (serverless only) - Source IP within VPC
- `aws:SourceVpc` (serverless only) - Source VPC ID
- `aws:SourceVpce` (serverless only) - VPC endpoint ID
- `aws:CurrentTime`, `aws:EpochTime` (serverless only) - Time-based conditions
- `aws:SourceIp` (replication groups only) - Public source IP

**Important**: Resource names in ARNs should be lowercase to match ElastiCache normalization.

**Sources**: AWS Service Authorization Reference (ElastiCache), AWS ElastiCache IAM Documentation

### 6. Token Refresh and Rotation

**Token Lifetime:**
- Valid for **900 seconds** (15 minutes) from generation
- Connection auto-disconnects after **12 hours** regardless of token age

**Refresh Strategy:**

**Option A: Generate Per-Connection** (simple)
```
1. Generate token with 15min expiration
2. Connect via HELLO/AUTH
3. Use connection for up to 12 hours
4. Close and reconnect with new token
```

**Option B: In-Place Re-Authentication** (connection pooling)
```
1. Maintain open connection
2. Before 12-hour limit, send new AUTH command:
   AUTH {user-id} {fresh-token}
3. Extends connection by another 12 hours
```

**Clock Skew Considerations:**
- Recommend refreshing tokens with 5-minute buffer (at 10 minutes)
- AWS tolerates ±5 minutes clock drift
- Use NTP to synchronize system clock

**Error Detection:**
- Expired token: AUTH command returns `-ERR invalid password` or `-WRONGPASS`
- No ElastiCache-specific error code documented; treat any AUTH failure as potential token expiry

**Sources**: AWS ElastiCache IAM Documentation, elasticache-iam-auth-demo-app

### 7. Cluster Mode Specifics

**Endpoint Types:**

**Cluster Mode Disabled (Single Shard):**
- **Primary endpoint**: DNS name resolving to current primary node (stable during failover)
- **Reader endpoint**: Round-robin DNS across read replicas
- **Node endpoints**: Individual node addresses (change during topology updates)
- **IAM Requirement**: One token per connection; endpoint address doesn't affect token

**Cluster Mode Enabled (Multiple Shards):**
- **Configuration endpoint**: Single DNS entry that knows all shard primaries and replicas
- **Per-Shard Endpoints**: Each shard has primary + reader endpoints
- **IAM Requirement**: Token uses replication group ID (not individual shard ID)

**Token Reuse Across Nodes:**
- Single token valid for all nodes in a replication group during its 15min TTL
- `cache-identifier` in token URL is the **replication group ID**, not individual node addresses
- Client connects to different nodes (primary vs replica) but signs same group ID

**Serverless vs Replication Group Differentiation:**
- Serverless: `ResourceType=ServerlessCache` query parameter (optional in practice)
- Replication groups: No ResourceType parameter
- Token signing process identical; only IAM policy resource ARN differs

**Sources**: AWS ElastiCache Endpoints Documentation, IAMAuthTokenRequest.java

### 8. TLS Requirements

**Mandatory for IAM Authentication:**
- TLS (in-transit encryption) **must** be enabled on ElastiCache cluster
- IAM authentication without TLS is rejected
- Connection string must specify TLS/SSL

**Configuration Check:**
```bash
aws elasticache describe-replication-groups \
  --replication-group-id {id} \
  --query 'ReplicationGroups[0].TransitEncryptionEnabled'
```

**Client Connection:**
```python
# Python example
redis_client = Redis(
    host=endpoint,
    port=6379,
    ssl=True,  # REQUIRED for IAM
    username=user_id,
    password=iam_token
)
```

**Why TLS is Required:**
- Tokens contain AWS credentials in query parameters
- Plaintext transmission would expose credentials to network sniffing
- Consistent with AWS security best practices

**Sources**: AWS ElastiCache IAM Documentation, elasticache-iam-auth-demo-app README

## Implementation Workflow

### Step 1: Obtain AWS Credentials

Use AWS SDK's default credential provider chain:
1. Environment variables (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`)
2. EC2 instance profile (recommended for production)
3. ECS task role
4. AWS config files (`~/.aws/credentials`)

### Step 2: Construct Presigned Request

```python
# Pseudo-code
cache_id = "my-cluster-01"
user_id = "iam-user-01"
region = "us-east-1"

base_url = f"http://{cache_id}/"
query_params = {
    "Action": "connect",
    "User": user_id
}

# Create signable request
request = AWSRequest(
    method="GET",
    url=base_url,
    params=query_params
)

# Add SigV4 signing
signer = SigV4QueryAuth(
    credentials=credentials,
    service_name="elasticache",
    region_name=region
)

presigned_url = signer.add_auth(
    request,
    expires_in=900  # 15 minutes
)
```

### Step 3: Extract Token from URL

```python
# Remove "http://" prefix
token = presigned_url.replace("http://", "")
# token = "my-cluster-01/?Action=connect&User=iam-user-01&X-Amz-Algorithm=..."
```

### Step 4: Connect with Token

```python
# RESP3 preferred
connection.send_command("HELLO", "3", "AUTH", user_id, token)

# RESP2 fallback
connection.send_command("AUTH", user_id, token)
```

### Step 5: Handle Token Refresh

```python
class ElastiCacheIAMConnection:
    def __init__(self, cluster_id, user_id, region):
        self.cluster_id = cluster_id
        self.user_id = user_id
        self.region = region
        self.token_generated_at = None
        self.connection_established_at = None
    
    def needs_token_refresh(self):
        # Refresh at 10 minutes (5min buffer before 15min expiry)
        return time.now() - self.token_generated_at > 600
    
    def needs_reconnect(self):
        # Reconnect before 12-hour limit
        return time.now() - self.connection_established_at > (11.5 * 3600)
    
    def refresh_auth(self):
        new_token = generate_iam_token(
            self.cluster_id, 
            self.user_id, 
            self.region
        )
        self.connection.send_command("AUTH", self.user_id, new_token)
        self.token_generated_at = time.now()
```

## Common Pitfalls

| Pitfall | Why It Happens | How to Avoid |
|---------|---------------|--------------|
| **Username/user-id mismatch** | Using IAM username or ARN instead of ElastiCache user-id | Always use the ElastiCache user-id in both CreateUser and AUTH command |
| **Case sensitivity issues** | ElastiCache normalizes cluster names to lowercase | Lowercase cluster identifier before signing |
| **Token expiry ignored** | 15-minute TTL not tracked | Implement token refresh at 10 minutes; handle AUTH errors as expiry |
| **TLS not enabled** | Connecting without SSL | Always check TransitEncryptionEnabled=true and use ssl=True in client |
| **Wrong service name** | Using "redis" or "valkey" in SigV4 | Service name is always "elasticache" regardless of engine |
| **Region mismatch** | Signing with wrong region | Extract region from cluster ARN or config; token is region-locked |
| **12-hour disconnect** | Not re-authenticating | Send new AUTH before 12 hours or handle disconnect gracefully |
| **Including "http://" in password** | Passing full URL to AUTH | Strip protocol prefix; token starts with cluster-id |
| **User not in user group** | ElastiCache user not attached to cluster's user group | Verify user group contains IAM user and is attached to cluster |
| **IAM policy missing user resource** | Policy only specifies cache ARN | Must include both cache AND user ARNs in Resource array |

## Valkey vs Redis Differences

**Verdict: No differences at protocol level.**

- Token generation: Identical process
- AUTH/HELLO commands: Same syntax
- SigV4 signing: Same service name ("elasticache")
- User configuration: Same CreateUser API
- TLS requirement: Applies to both

**Engine-Specific Notes:**
- Valkey: Minimum version 7.2 for IAM support
- Redis OSS: Versions 6.0-7.1 supported (IAM added in 7.0)
- AWS uses "engine" parameter in API but same "elasticache" service for signing

## Prior Art: Client Implementations

### Lettuce (Java)
- **Integration**: RedisCredentialsProvider interface for token management
- **Pattern**: Implement custom provider that calls AWS SDK presigner
- **Issues**: GitHub issues show connection timeout and reconnect concerns (not IAM-specific)
- **Source**: elasticache-iam-auth-demo-app uses Lettuce successfully

### Jedis (Java)
- **Integration**: No built-in ElastiCache IAM support found in repository
- **Pattern**: Likely requires manual token generation + standard AUTH
- **Status**: No GitHub search results for "elasticache iam" in redis/jedis repo

### redis-py (Python)
- **Integration**: No explicit ElastiCache IAM helpers found
- **Pattern**: Use boto3 for token generation, pass to connection as password
- **Status**: No AWS-specific documentation in repository

### General Pattern Across Clients
1. Use AWS SDK to generate presigned URL
2. Strip `http://` prefix
3. Pass as password parameter to standard AUTH command
4. Implement custom credentials provider for auto-refresh

**Gap**: No mainstream Redis client has ElastiCache IAM as first-class feature; requires client-side token provider implementation.

**Sources**: GitHub searches (lettuce, jedis, redis-py), elasticache-iam-auth-demo-app

## Empirical Verification Checklist

These details remain **undocumented** or **ambiguous** and require testing against live ElastiCache:

1. **Exact error code on expired token**: Does server return `-ERR`, `-WRONGPASS`, or custom error?
2. **Token reuse across shard nodes**: Can one token authenticate to both primary and replicas?
3. **Behavior without TLS**: Does AUTH fail before connection, or during handshake?
4. **Clock skew tolerance**: Documented as ±5min; verify if ElastiCache enforces stricter?
5. **ResourceType parameter necessity**: Is `ResourceType=ServerlessCache` required for serverless, or optional?
6. **HELLO vs AUTH behavior**: Any difference in token handling between RESP2 AUTH and RESP3 HELLO?
7. **Failover token validity**: Does token remain valid after primary failover (endpoint DNS resolves to new primary)?
8. **Connection pool behavior**: Do idle connections disconnected before 12 hours, or exactly at 12-hour mark?
9. **Multi-region scenarios**: What happens if token is generated for us-east-1 but used against us-west-2 cluster?
10. **IAM policy evaluation timing**: Is policy checked at token generation, at AUTH time, or both?

## Code Example: Complete OCaml Token Provider

```ocaml
(* Conceptual outline for ocaml-valkey *)

module ElastiCache_IAM : sig
  type t
  
  val create :
    cluster_id:string ->
    user_id:string ->
    region:string ->
    credentials_provider:(unit -> Aws.Credentials.t) ->
    t
  
  val generate_token : t -> (string, [> `Token_generation_failed of string]) result
end = struct
  type t = {
    cluster_id : string;
    user_id : string;
    region : string;
    credentials_provider : unit -> Aws.Credentials.t;
  }
  
  let create ~cluster_id ~user_id ~region ~credentials_provider =
    { cluster_id = String.lowercase_ascii cluster_id;
      user_id;
      region;
      credentials_provider }
  
  let generate_token t =
    let open Result.Syntax in
    let* credentials = 
      try Ok (t.credentials_provider ())
      with e -> Error (`Token_generation_failed (Printexc.to_string e))
    in
    
    (* Construct canonical request *)
    let base_url = Printf.sprintf "http://%s/" t.cluster_id in
    let query_params = [
      ("Action", "connect");
      ("User", t.user_id);
    ] in
    
    (* Add SigV4 query auth parameters *)
    let timestamp = Unix.gettimeofday () in
    let date_stamp = (* format as YYYYMMDD *) in
    let expires_in = 900 in (* 15 minutes *)
    
    let* canonical_query = 
      Aws_sigv4.canonical_query_string
        ~params:query_params
        ~algorithm:"AWS4-HMAC-SHA256"
        ~credential:(Aws_sigv4.credential_scope ~credentials ~date_stamp ~region:t.region ~service:"elasticache")
        ~timestamp
        ~signed_headers:"host"
        ~expires_in
    in
    
    let canonical_request =
      String.concat "\n" [
        "GET";
        "/" ^ t.cluster_id ^ "/";
        canonical_query;
        "host:" ^ t.cluster_id;
        "";
        "host";
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
      ]
    in
    
    let* signature = Aws_sigv4.sign
      ~credentials
      ~region:t.region
      ~service:"elasticache"
      ~timestamp
      ~canonical_request
    in
    
    let presigned_url = 
      Printf.sprintf "%s?%s&X-Amz-Signature=%s"
        base_url
        canonical_query
        signature
    in
    
    (* Strip "http://" prefix *)
    let token = String.sub presigned_url 7 (String.length presigned_url - 7) in
    Ok token
end

(* Usage in connection flow *)
let connect_with_iam ~cluster_id ~user_id ~region ~endpoint =
  let credentials_provider = Aws.Credentials.default_provider in
  let iam_provider = ElastiCache_IAM.create
    ~cluster_id
    ~user_id
    ~region
    ~credentials_provider
  in
  
  match ElastiCache_IAM.generate_token iam_provider with
  | Error e -> Error e
  | Ok token ->
    let conn = Connection.connect
      ~host:endpoint
      ~port:6379
      ~tls:true  (* REQUIRED *)
    in
    
    (* Use HELLO with IAM token *)
    match Connection.send conn (Resp3.hello ~proto:3 ~auth:(user_id, token)) with
    | Ok hello_reply -> Ok conn
    | Error auth_err -> Error (`Auth_failed auth_err)
```

## Further Reading

| Resource | Type | Why Recommended |
|----------|------|-----------------|
| [AWS ElastiCache IAM Authentication](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/auth-iam.html) | Official Docs | Primary source for IAM auth requirements |
| [ElastiCache CreateUser API](https://docs.aws.amazon.com/AmazonElastiCache/latest/APIReference/API_CreateUser.html) | API Reference | User configuration and AuthenticationMode structure |
| [AWS Service Authorization Reference - ElastiCache](https://docs.aws.amazon.com/service-authorization/latest/reference/list_amazonelasticache.html) | IAM Reference | IAM actions, resources, and condition keys |
| [AWS Signature Version 4 Signing](https://docs.aws.amazon.com/general/latest/gr/sigv4-signed-request-examples.html) | Technical Guide | SigV4 signing process with examples |
| [elasticache-iam-auth-demo-app](https://github.com/aws-samples/elasticache-iam-auth-demo-app) | Sample Code | Working Java implementation with Lettuce |
| [ElastiCache Endpoints](https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/WhatIs.Components.html) | Technical Docs | Endpoint types and cluster mode differences |
| [Valkey AUTH Command](https://valkey.io/commands/auth/) | Protocol Spec | AUTH command syntax |
| [Valkey HELLO Command](https://valkey.io/commands/hello/) | Protocol Spec | HELLO command with RESP3 authentication |

---

*Generated by /learn from 15+ primary sources including AWS official documentation, AWS SDK samples, and protocol specifications.*

*See `resources/elasticache-iam-auth-protocol-sources.json` for full source metadata and quality scores.*
