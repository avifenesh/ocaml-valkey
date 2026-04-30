# Security

Advice for shipping this client against an internet-facing or
multi-tenant Valkey. Not exhaustive — defer to your security
team for the authoritative threat model.

## What goes on the wire

Every command the client sends is RESP3 over either:

- Plaintext TCP (`Connection.Config.tls = None`) — **don't use
  this outside loopback or a fully-trusted network**.
- TLS via `ocaml-tls` — see [tls.md](tls.md).

AUTH credentials, transaction payloads, `SET` values, `EVAL`
scripts — all of that flows through the same socket. If it's
sensitive, TLS is non-negotiable.

## AUTH

Valkey has two AUTH shapes:

- Legacy single-password: `AUTH <password>`.
- ACL users: `AUTH <username> <password>`.

The client wires both via `Connection.Config`:

```ocaml
let config =
  { Valkey.Connection.Config.default with
    auth = Some { username = Some "app-prod"; password = "…" };
    tls = Some (Valkey.Tls_config.system_cas ()) }
```

`AUTH` runs inside the `HELLO` handshake, which runs inside the
TLS tunnel, so the password never leaves the encrypted channel.

**Don't put secrets in source control.** Read from env / secret
store at startup:

```ocaml
let password =
  try Sys.getenv "VALKEY_PASSWORD"
  with Not_found -> failwith "set VALKEY_PASSWORD"
```

## ACLs

Use per-service ACL users with the minimum commands they need.
Start with `+@read +@write +@connection -@dangerous`, then
tighten.

A few pitfalls to know about:

- ACL applies to the whole connection. If one service needs a
  different ACL, use a different `Client.t` (and probably a
  different user).
- `ACL WHOAMI` is keyless — any node can answer, but the answer
  only tells you who you are on *that* connection.
- Some commands are silently dropped (not errored) under
  restricted ACLs. Test your subscribing ACL with an actual
  `SUBSCRIBE` — don't assume.

## IAM (AWS ElastiCache)

AWS ElastiCache for Valkey supports IAM-token authentication
instead of a static password; tokens are short-lived
SigV4-presigned URLs. This library has a built-in, pure-OCaml
SigV4 signer + refresh provider — no AWS SDK dependency.

```ocaml
(* 1. Credentials from your environment / config / Vault / … *)
let creds =
  match Valkey.Iam_credentials.of_env () with
  | Ok c -> c
  | Error msg -> failwith ("AWS creds: " ^ msg)
in

(* 2. Provider: signs an initial token + spawns a 10-minute
      refresh fiber on [sw]. *)
let iam =
  Valkey.Iam_provider.create
    ~sw ~clock
    ~credentials:creds
    ~config:(Valkey.Iam_provider.Config.default
               ~user_id:"iam-user-01"
               ~cluster_id:"my-cluster"
               ~region:"us-east-1")
in

(* 3. Connect — IAM auth installed on the handshake, TLS is
      required by ElastiCache. *)
let tls =
  Valkey.Tls_config.with_system_cas
    ~server_name:"my-cluster.abc.cache.amazonaws.com" ()
  |> Result.get_ok
in
let config =
  { Valkey.Client.Config.default with
    connection =
      { Valkey.Connection.Config.default with tls = Some tls } }
in
let client =
  Valkey.Client.connect_with_iam ~sw ~net ~clock ~config ~iam
    ~host:"my-cluster.abc.cache.amazonaws.com" ~port:6379 ()
in
(* Use [client] normally — the 10-minute refresh fiber pushes
   fresh tokens in place without disturbing the socket; on AUTH
   failure the connection falls through to the reconnect
   supervisor, which rehandshakes with a freshly-signed token. *)
```

### Cluster mode

ElastiCache serverless and cluster-mode replication groups both
expose a single configuration endpoint; you wire the IAM provider
into `Cluster_router.Config` and the library takes care of every
shard connection — including any node that appears later via
topology refresh — from the same provider:

```ocaml
let iam = (* as above *) in
let cluster_cfg =
  let base = Valkey.Cluster_router.Config.default ~seeds in
  Valkey.Client.install_iam_on_cluster_config base iam
  (* IAM provider now installed on
     [base.connection.handshake.auth]. *)
in
let router =
  match Valkey.Cluster_router.create ~sw ~net ~clock ~config:cluster_cfg ()
  with
  | Ok r -> r
  | Error e -> failwith ("cluster router: " ^ e)
in
let client =
  Valkey.Client.from_router_with_iam
    ~sw ~net ~clock ~config:Valkey.Client.Config.default
    ~iam router
in
(* Use [client] normally. The provider's refresh fiber walks
   [Router.all_connections router] on every tick, so new nodes
   that join via topology refresh get AUTH-pushed too. *)
```

Protocol constraints the library enforces for you:
- TLS is mandatory — ElastiCache rejects IAM over plaintext.
- The ElastiCache `user-id` and `user-name` must be identical
  (lowercase); the provider passes it through verbatim.
- Tokens have a 15-minute TTL and the server tolerates ±5 min
  of clock skew — the 10-minute refresh cadence is well inside
  both windows.
- The 12-hour server-side auto-disconnect is orthogonal — when
  it fires, the Connection's reconnect supervisor re-handshakes
  with a freshly-signed token from the same provider.

See `docs/tls.md` for TLS details and `Valkey.Iam_provider` in
the odoc for the full provider surface.

### Smoke-testing against a real ElastiCache cluster

`bin/iam_smoke/` is a standalone binary for manually verifying
the IAM path end-to-end against your own ElastiCache for Valkey
deployment. Not wired into CI; run it yourself when you want
proof-of-life:

```sh
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_REGION=us-east-1
export ELASTICACHE_HOST=my-cluster.abc.cache.amazonaws.com
export ELASTICACHE_CLUSTER_ID=my-cluster
export ELASTICACHE_USER_ID=iam-user-01
# Optional:
# export AWS_SESSION_TOKEN=...           # STS / IRSA case
# export SMOKE_DURATION_SECONDS=900      # 15 min — crosses one refresh
# export IAM_REFRESH_INTERVAL=600        # default 10 min
# export SMOKE_OPS_PER_SECOND=50

dune exec bin/iam_smoke/iam_smoke.exe
```

The binary runs a `SET` every ~20 ms against a throwaway key,
watches the cached token rotate via `Iam_provider.current_token`,
and reports op success/error counts plus the number of token
rotations observed. Exits 0 on success; non-zero on failing op
or zero-rotation runs long enough to cross a refresh boundary.

## Secrets in the repo

No production secrets land here. A grep sweep
(`grep -riE '(password|token|secret|api_?key)\s*[:=]\s*"[^"]+"'`)
over `scripts/`, `lib/`, `test/`, and `bin/` returns zero hits
for production-shaped secret literals. Test fixtures use inline
throwaway passwords set via `ACL SETUSER` and deleted in
teardown — never hardcoded elsewhere.

Standard rule: `.env` files are gitignored; CI secrets live in
the provider's secret store.

## TLS — specifics

See [tls.md](tls.md) for the full picture. Key do's and don'ts:

- ✅ Use `Tls_config.with_system_cas ()` against services with
  publicly-signed certs (ElastiCache, hosted Valkey).
- ✅ Use `Tls_config.with_ca_cert` with your private CA for
  internal clusters.
- ✅ Use `Tls_config.with_client_cert` for mTLS (see
  [tls.md](tls.md)).
- ❌ Never use `Tls_config.insecure` in production. It disables
  certificate verification entirely.
- ❌ Don't pin to specific cipher suites unless you know why —
  `ocaml-tls`'s defaults are current.

## Audit of what goes where

| Data                | Destination                  | Protection |
|---------------------|------------------------------|------------|
| AUTH password       | Server, once at handshake    | TLS        |
| Command args (keys + values) | Server, every command | TLS        |
| Function / Lua src  | Server, at `FUNCTION LOAD`   | TLS        |
| Client logs         | stderr (no built-in logging) | Local     |
| Bench / fuzz results | CI artifacts                | GH perms   |

The client does not send telemetry anywhere. No phone-home, no
auto-upload of crash reports.

## Multi-tenant environments

If multiple applications share a Valkey:

- Use ACL per service. Don't share a root-level password.
- Use a separate keyspace prefix per service (`svc-a:…`,
  `svc-b:…`). Prevents accidental cross-reads.
- For cluster mode, pin keyspace prefixes to known slot ranges
  using hashtags so capacity-planning is predictable.
- `FLUSHALL` needs careful ACL gating — it'll wipe everyone.

## Reporting vulnerabilities

For security issues, please email the maintainer directly rather
than opening a public issue. Responses within 72 hours.

## See also

- [tls.md](tls.md) — TLS configuration, dev certs, mTLS.
- [cluster.md](cluster.md) — `prefer_hostname` and how the
  client resolves cluster addresses.
