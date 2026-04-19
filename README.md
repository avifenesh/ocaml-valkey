# valkey-ocaml

A modern Valkey client for OCaml 5 + [Eio](https://github.com/ocaml-multicore/eio).

**Status: alpha.** Core feature surface is in — standalone, cluster (with routing + refresh + failover), transactions, pub/sub (regular + sharded, auto-resubscribe), typed commands, a stability fuzzer, a parser fuzzer, and a pre-push gate that ties them together. 153 tests pass. Not yet published to opam.

## Why

Existing OCaml Redis clients predate Valkey, target RESP2, and use Lwt or Async. This project targets the current era of both stacks:

- **OCaml 5.3+**, Eio-native (effects-based, direct-style concurrency)
- **RESP3 only** — no RESP2 fallback
- **Valkey 7.2+**, with first-class support for Valkey 8/9 features (HELLO `availability_zone`, `SET IFEQ`, `DELIFEQ`, hash field TTL, sharded pub/sub)

No Lwt compat layer. No legacy Redis support.

## What you get

### Connection spine

- Auto-reconnect with configurable backoff + jitter; HELLO / AUTH / SETNAME / SELECT replayed on every reconnect
- Byte-budget backpressure (not count-based)
- Always-on circuit breaker with a conservative default
- App-level keepalive fibre
- Full TLS support (self-signed or system CA bundle)
- Optional cross-domain split: parser stays on the user's domain; socket I/O runs on a dedicated `Eio.Domain_manager` thread so long parses can't stall the pipeline
- Contracts: user command timeouts honoured; commands never silently dropped
- `?on_connected` hook — fires after every successful handshake (used by `Pubsub` to replay subscriptions)

### Cluster router

- CRC16-XMODEM slot hashing with hashtag support
- `CLUSTER SHARDS` parser (Valkey 9 rich format)
- Quorum-based topology discovery from seed addresses; canonical-SHA change detection
- MOVED / ASK redirect retry (bounded, `ASKING` sent before the retried command on `ASK`)
- CLUSTERDOWN / TRYAGAIN retry with exponential back-off (up to ~3 s)
- Interrupted / Closed retry so callers don't see transient tear-downs
- Periodic background refresh fibre (15 s base + jitter, wakes early on unknown-address redirects)
- Seed fallback when the live pool can no longer reach quorum
- Typed `Read_from` (Primary / Prefer_replica / AZ-affinity)
- `Target` types for `by_slot` / `by_node` / `random`; `Fan_target` for `All_nodes` / `All_primaries` / `All_replicas`
- **Standalone = one-shard cluster** — single-node connections go through the same router behind a synthetic topology; dispatch is unified

### Typed commands

- ~90 typed helpers across strings, counters, TTL, hashes (incl. field TTL), sets, lists, sorted sets, streams (non-blocking + consumer groups + admin), scripting (with automatic `EVALSHA → EVAL` fallback on `NOSCRIPT`), blocking commands.
- **Per-command default routing** (`Command_spec`): ~230 command + sub-command entries. `Client.set "k" v` routes to `slot(k)`'s primary; `Client.get "k"` respects the caller's `Read_from`; writes are forced to `Primary`.
- **Cluster-aware admin**: `SCRIPT LOAD/FLUSH/EXISTS` and `KEYS` fan to every primary and aggregate so they behave identically in standalone and cluster.
- **Custom commands** via `Client.custom` / `custom_multi` — any Valkey command (including ones we don't wrap typed-side) routes correctly.
- **Named / registered commands** via `Named_commands`: register a template once (`[| "HSET"; "$1"; "$2"; "$3" |]`) and invoke by name; same for named transactions.

### Transactions

- `Valkey.Transaction.begin_ / queue / exec / discard` + `with_transaction` scope helper.
- Pins the MULTI / EXEC block to `slot(hint_key)`'s primary.
- `exec` returns `(Resp3.t list option, Error.t) result` — `Ok None` on WATCH abort.

### Pub/sub

Two handles that cover the whole pub/sub surface:

- **`Pubsub.t`** — dedicated subscriber connection. Typed `message` variants (Channel / Pattern / Shard). Tracks the subscription set under a mutex; on every reconnect, the `on_connected` hook replays `SUBSCRIBE` / `PSUBSCRIBE` / `SSUBSCRIBE`. Verified by an integration test that runs `CLIENT KILL TYPE pubsub` mid-traffic and asserts delivery resumes.
- **`Cluster_pubsub.t`** — cluster-aware. One handle covers regular pub/sub (global connection, broadcast across shards on Valkey 7+) and sharded pub/sub (one pinned connection per subscribed slot). A watchdog fibre polls `Router.endpoint_for_slot` every second; when a primary changes (failover), the shard connection is closed, reopened at the new address, and `on_connected` replays the slot's `SSUBSCRIBE` set. Verified by an integration test that `docker restart`s every primary in sequence and asserts post-failover delivery.

Publish side has typed `Client.publish` (cluster-wide broadcast) and `Client.spublish` (slot-pinned).

### Chaos-tested stability

A 3-minute cluster fuzz with 5 forced primary restarts at ~12 k ops/s finishes with **zero user-visible errors** — MOVED / ASK / CLUSTERDOWN / TRYAGAIN / Interrupted all absorbed by the retry machinery. See `bin/fuzz/fuzz.ml`.

### Benchmarks

Apples-to-apples with [ocaml-redis](https://github.com/0xffea/ocaml-redis) (RESP2, blocking) and `valkey-benchmark` (the C client, as a reference ceiling):

| Scenario            |       Ours | ocaml-redis |        C | Ours/C | Ours/ocaml-redis |
|---------------------|-----------:|------------:|---------:|-------:|-----------------:|
| SET 100 B conc=1    |  7.3 k r/s |   8.5 k r/s |  8.8 k   |  83 %  |           0.86x  |
| GET 100 B conc=100  |  199 k r/s |    60 k r/s |  202 k   |  99 %  |         **3.3x** |
| MIX 1 KiB conc=100  |  110 k r/s |    47 k r/s |    —     |   —    |         **2.3x** |
| SET 16 KiB conc=10  |   49 k r/s |    26 k r/s |   55 k   |  91 %  |           1.9x   |

At high concurrency we're **3-3.5× faster than ocaml-redis and within 85-96 % of the C reference** across 100 B scenarios. Full matrix, methodology, and send-path optimisation history in [BENCHMARKS.md](BENCHMARKS.md). Run it yourself with `bash scripts/run-bench.sh`.

### Developer tooling

- **Parser fuzzer** (`bin/fuzz_parser/`): byte-level fuzzer for the RESP3 parser. ~110 k inputs/s. Catches contract violations (any exception outside `Parse_error` / `End_of_stream`). Gated into pre-push at 100 k iterations per run.
- **Stability fuzzer** (`bin/fuzz/`): live-server soak with 48 commands across every data type, optional docker-restart chaos, bucketed latency, per-outcome tallies.
- **Benchmark harness** (`bin/bench/`, `bin/bench_redis/`) + shell runner.
- **Pre-push gate**: build + full test suite + parser fuzz + 30 s standalone fuzz + 30 s cluster fuzz (if the cluster is up) with zero-error thresholds.

## Installation

Requires OCaml 5.3+ and opam 2.2+.

```sh
opam install . --deps-only --with-test
dune build
```

Not yet published to the opam repository.

## Quick start

```ocaml
let () =
  Eio_main.run @@ fun env ->
  Eio.Switch.run @@ fun sw ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let client =
    Valkey.Client.connect
      ~sw ~net ~clock
      ~host:"localhost" ~port:6379 ()
  in

  let _ = Valkey.Client.set client "greeting" "hello" in
  (match Valkey.Client.get client "greeting" with
   | Ok (Some v) -> Printf.printf "got: %s\n" v
   | Ok None     -> print_endline "no value"
   | Error e     ->
       Format.printf "error: %a\n" Valkey.Connection.Error.pp e);

  Valkey.Client.close client
```

### Connecting to a cluster

```ocaml
let config =
  Valkey.Cluster_router.Config.default
    ~seeds:[ "node-a.example.com", 6379;
             "node-b.example.com", 6379;
             "node-c.example.com", 6379 ]
in
match Valkey.Cluster_router.create ~sw ~net ~clock ~config () with
| Error m -> failwith m
| Ok router ->
    let client =
      Valkey.Client.from_router ~config:Valkey.Client.Config.default router
    in
    let _ = Valkey.Client.set client "user:42" "ada" in
    ...
```

The router discovers topology from the seeds via quorum, opens a connection per node, handles MOVED/ASK/CLUSTERDOWN/TRYAGAIN, refreshes periodically in the background, and falls back to re-resolving from the seeds if the pool can no longer reach quorum.

### Transactions

```ocaml
match
  Valkey.Transaction.with_transaction client ~hint_key:"user:42" @@ fun tx ->
  let _ = Valkey.Transaction.queue tx [| "HSET"; "user:42"; "seen"; "now" |] in
  let _ = Valkey.Transaction.queue tx [| "EXPIRE"; "user:42"; "3600" |] in
  ()
with
| Ok (Some replies) -> (* committed, replies[i] = result of the i-th queued command *)
| Ok None           -> (* WATCH abort — caller decides whether to retry *)
| Error e           -> (* transport / protocol failure *)
```

### Pub/sub (cluster-aware)

```ocaml
let cp =
  Valkey.Cluster_pubsub.create ~sw ~net ~clock ~router ()
in
let _ = Valkey.Cluster_pubsub.ssubscribe cp [ "orders:created" ] in

let rec loop () =
  match Valkey.Cluster_pubsub.next_message ~timeout:30.0 cp with
  | Ok (Shard { channel; payload }) ->
      Printf.printf "[%s] %s\n%!" channel payload;
      loop ()
  | Error `Timeout -> loop ()
  | Error `Closed  -> ()
in
loop ()
```

On primary failover, the watchdog re-pins the slot's connection and the new connection's `on_connected` replays `SSUBSCRIBE` automatically — the caller does nothing.

### Named commands

```ocaml
let nc = Valkey.Named_commands.create client in
Valkey.Named_commands.register_command nc
  ~name:"user-email"
  ~template:[| "HGET"; "$1"; "email" |] ();

match Valkey.Named_commands.run_command nc
        ~name:"user-email" ~args:["user:42"] with
| Ok (Valkey.Resp3.Bulk_string email) -> ...
| _ -> ...
```

Same pattern for transactions via `register_transaction` + `run_transaction`.

### With TLS against a managed service

```ocaml
let tls =
  match Valkey.Tls_config.with_system_cas
          ~server_name:"your.redis.amazonaws.com" () with
  | Ok t -> t | Error m -> failwith m
in
let config =
  { Valkey.Client.Config.default with
    connection = { Valkey.Connection.Config.default with tls = Some tls } }
in
let client = Valkey.Client.connect ~sw ~net ~clock ~config
               ~host:"your.redis.amazonaws.com" ~port:6379 () in
...
```

## Development setup

Requires: Docker, OCaml 5.3+, opam 2.2+.

```sh
# One-time: generate self-signed certs for the TLS integration tests
bash scripts/gen-tls-certs.sh

# Start a local Valkey 9 on :6379 (plain) and :6390 (TLS)
docker compose up -d

# Optional: spin up a 3-primary / 3-replica cluster for integration tests
sudo bash scripts/cluster-hosts-setup.sh     # one-time: /etc/hosts entries
docker compose -f docker-compose.cluster.yml up -d

# Build and run everything
dune build
dune runtest
```

## Architecture

Four layers, bottom up:

- **`Connection`** owns one socket and the protocol state machine (`Connecting → Alive → Recovering → Dead`). Pipelines commands through a write fibre and drains replies through a parser fibre; optionally splits I/O across domains. Provides `request` (reply-matched) and `send_fire_and_forget` (no reply expected, used by `Pubsub`).
- **`Cluster_router`** owns the fleet: topology discovery, node pool, slot dispatch, redirect retry, periodic refresh, seed fallback, typed `Read_from` / `Target` / `Fan_target`. Standalone is wrapped as a synthetic single-shard cluster through the same dispatch path.
- **`Client`** is the typed command surface built on any `Router.t`. Handles `Command_spec`-driven routing, fan-out aggregation, and the `Client.custom` escape hatch.
- **`Transaction`** / **`Pubsub`** / **`Cluster_pubsub`** / **`Named_commands`** sit beside `Client` and use its primitives. Each is a small, focused module with its own integration tests.

## Pre-push gate

`scripts/git-hooks/pre-push` runs `dune build`, the full test suite, the parser fuzz at 100 k iterations (strict), and a 30-second stability fuzz (both standalone and, if up, the cluster) with a **zero-error threshold**. Set it up once:

```sh
bash scripts/install-git-hooks.sh
```

Override knobs:
- `SKIP_FUZZ=1 git push` — skip fuzz steps (still runs build + tests + parser fuzz).
- `SKIP_PRE_PUSH=1 git push` — emergency escape.
- `FUZZ_SECONDS=60 git push` — longer fuzz window.

## Roadmap

Scope for next sessions, roughly in order:

1. Polish & publish to opam.
2. Larger-scale bench matrix on real hardware (not WSL), document expected ratios on Linux bare-metal.
3. AZ-affinity verification against a real multi-AZ ElastiCache deployment.
4. Property-based tests over `Command_spec` (every spec entry's `By_slot` actually routes to a node that owns that slot in a live cluster).
5. Additional typed commands for the long tail users ask for (driven by what turns up).

## License

MIT. See [LICENSE](LICENSE).
