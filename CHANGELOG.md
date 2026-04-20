# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added — typed sorted-set wrappers

The leaderboard example surfaced this gap; the wrappers below
replace the `Client.custom` calls that example was using:

- `zadd` — with `?cond:Z_nx|Z_xx`, `?compare:Z_gt|Z_lt`, `?ch`.
  Takes `(score, member) list`. Returns count of newly added
  (or with `~ch:true`, count of added + score-changed).
- `zadd_incr` — separate function so the return type tracks the
  reply. Returns `float option`: the new score on success,
  `None` when NX/XX/GT/LT prevented the write.
- `zincrby` — atomic increment, returns the new score as `float`.
- `zrem` — returns count of members actually removed.
- `zrank` / `zrevrank` — `int option`, `None` when missing.
- `zrank_with_score` / `zrevrank_with_score` — Valkey 7.2+
  WITHSCORE variant, returns `(int * float) option`.
- `zscore` — `float option`, `None` when missing.
- `zmscore` — multi-member; returns `float option list` parallel
  to the input list.
- `zcount` — count members in a score range.
- `zrange_with_scores` / `zrangebyscore_with_scores` — return
  `(string * float) list` instead of just members.
- `zpopmin` / `zpopmax` — atomic pop with optional count;
  returns `(string * float) list`.

Score parsing handles both RESP3 `Double` and `Bulk_string`
shapes (different commands and server versions emit different
encodings).

`examples/09-leaderboard/` is now typed end-to-end (no
`Client.custom` left).

### Added — Phase 5 (examples)

- Initial set of 9 runnable example programs under `examples/`:
  01-hello (strings/counters/hashes/streams/consumer groups),
  02-cluster (Read_from modes + TLS template), 03-pubsub,
  04-transaction (WATCH retry), 05-cache-aside (hash field TTL),
  06-distributed-lock (SET NX EX + CAD release), 07-task-queue
  (streams + consumer groups + XAUTOCLAIM), 08-blocking-commands
  (BRPOP), 09-leaderboard (sorted-set).
- `examples/README.md` documents the set and the convention.
- `CONTRIBUTING.md` updated: new significant features land with
  the example that exercises them.

### Changed

- `Cluster_router.pick_node_by_read_from` now picks a random
  replica for `Prefer_replica` and `Az_affinity` modes (was
  always the first replica, which pinned all reads from one
  client to a single replica). Spreads readonly traffic across
  the replica set.

### Known gaps surfaced by examples

- Sorted-set commands `ZADD`, `ZINCRBY`, `ZRANK`, `ZSCORE`,
  `ZREVRANGE` are not yet typed wrappers — the leaderboard
  example uses `Client.custom` for them. Wrapping them is on the
  pre-1.0 list.

### Added — Phase 4 (documentation)

- `docs/` — 9 hand-written guides covering getting-started, cluster,
  transactions, pub/sub, TLS, performance, troubleshooting,
  security, and migration from `ocaml-redis`.
- `CONTRIBUTING.md` at repo root — build/test/fuzz/bench/coverage
  workflow, style rules, PR checklist.
- `CHANGELOG.md` rewritten to explicitly cover Phases 0 → 3 (was
  stale, reported 82 tests).
- `.github/workflows/docs.yml` — builds odoc HTML on every push/PR,
  stages guides under `/guides/`, deploys to `gh-pages` on main.
- `dune build @doc` is warning-clean on all 20 modules; the
  previously-hidden constructor warning on `Connection.Error.t`
  was resolved during this pass.

### Added — Phase 3 (CI/CD + coverage)

- GitHub Actions workflows:
  - `ci.yml` — Ubuntu × OCaml {5.3, 5.4} integration (docker
    standalone + cluster, full tests, 100k parser fuzz strict, 30s
    standalone + 30s cluster stability fuzz). macOS × OCaml {5.3,
    5.4} portability subset (docker-free tests + 50k parser fuzz).
  - `coverage.yml` — bisect_ppx instrumentation, HTML artifact, 60
    % floor (baseline 63 %), gh-pages deploy of the report on main.
  - `fuzz-nightly.yml` — scheduled 02:00 UTC. 200M parser fuzz
    strict + 15 min cluster stability with docker-restart chaos.
    Auto-opens an issue on non-zero exit.
  - `bench.yml` — per-PR delta table vs `main` with a 10%
    regression gate; pushes to `main` stash the baseline on the
    `bench-history` branch.
- `bin/bench_compare/` — zero-dep bench-JSON diff tool producing
  GitHub-flavoured markdown tables.
- `bin/bench/` gained `--json PATH` output.
- `bisect_ppx` is a new `with-dev-setup` dependency; `lib/dune`
  declares it as the instrumentation backend.

### Added — Phase 2 (testing rigour + audit)

- `test/test_resp3_roundtrip.ml` — randomised round-trip proptest,
  10k random leaves + 10k nested trees + targeted edge cases
  (empty aggregates, bulk-with-CRLF, int64 extremes, inf/NaN,
  exotic map keys). Hand-rolled generator, no new dep.
- `test/test_command_spec_property.ml` — three cluster-level
  properties: 500 random-keyed round-trips, every-slot endpoint
  coverage, Read_from.Prefer_replica actually reaches replicas.
- `test/test_retry_state.ml` — nine focused tests over the retry
  state machine via `Cluster_router.For_testing`: ok /
  non-retryable / TRYAGAIN / CLUSTERDOWN (×2, incl. exponential
  schedule + budget exhaustion) / Interrupted / Closed / mixed /
  backoff schedule.
- Parser fuzzer upgrades: tree-level structural mutation (swap /
  duplicate / reverse sublist / recursively mutate), length-field
  poisoning on every declared aggregate/bulk header, and a
  delta-debug shrinker that prints the minimal reproducer on
  failure. 10 M strict clean at ~145k inputs/s on the new
  six-strategy mix.
- `bin/soak/` — long-running stability soak. Steady SET/GET/DEL
  workload with a sampler recording `Gc.quick_stat` heap + top +
  live, `/proc/self/fd` count, total ops every N seconds. OLS
  slope detection flags heap or fd leaks; `--strict` exits 1 on
  threshold breach.
- `docker-compose.toxiproxy.yml` + `scripts/chaos/chaos.sh` — TCP
  chaos via toxiproxy. Subcommands: setup / latency / loss /
  bandwidth / reset / close / clear / teardown. Point bin/fuzz,
  bin/soak, or bin/bench at the proxy ports for chaos runs.
- `AUDIT.md` — inventory of every `Obj.magic`, `try _ with _ -> ()`,
  `ignore (_ : _ result)`, `mutable` field (+ lock discipline),
  and `Atomic.*` site, each with a disposition.
- `Cluster_router.For_testing` — exposes `handle_retries` and the
  backoff constants so the retry loop can be driven from unit
  tests without a real pool.

### Changed — Phase 2

- Deleted the dead `watchdog` function in `cluster_pubsub.ml` —
  it contained an `Obj.magic ()` landmine (never executed, but
  dangerous to leave around); the correct implementation was
  already inlined in `create`.
- `Connection.close` and `Cluster_router.close` now guard with
  `Atomic.exchange closing true`, making repeat calls a true no-op
  instead of relying on each inner step being re-invokable.
- Added a locking-discipline comment at the top of
  `cluster_pubsub.ml` documenting the `shards_mutex` /
  `subs_mutex` contract.
- Narrowed all 14 drain-path `try ... with _ -> ()` sites to the
  specific exceptions that legitimately arise on teardown
  (`Eio.Io _ | End_of_file | Invalid_argument _ | Unix.Unix_error
  _` for close paths; `Invalid_argument _` for
  `Eio.Promise.resolve`). Anything else now surfaces instead of
  being silently swallowed.

### Added — Phase 1 (command surface completion)

- **Bitmap**: `BITCOUNT`, `BITPOS`, `BITOP`, `SETBIT`, `GETBIT`,
  `BITFIELD`, `BITFIELD_RO`. `bit_range` is a sum type (`From`,
  `From_to`, `From_to_unit`) matching Valkey 8.0+ semantics, and
  `BITOP NOT` is encoded with arity-at-type-level
  (`Bitop_not of string` takes exactly one source).
- **HyperLogLog**: `PFADD`, `PFCOUNT`, `PFMERGE`.
- **Generic keyspace**: `COPY`, `DUMP`, `RESTORE`, `TOUCH`,
  `RANDOMKEY`, `OBJECT ENCODING|REFCOUNT|IDLETIME|FREQ`.
- **Geo**: `GEOADD`, `GEODIST`, `GEOPOS`, `GEOHASH`, `GEOSEARCH`,
  `GEOSEARCHSTORE` with typed `geo_from`, `geo_shape`,
  `geo_search_result`.
- **CLIENT admin**: `CLIENT ID|GETNAME|SETNAME|INFO|LIST|PAUSE|
  UNPAUSE|NO-EVICT|NO-TOUCH|KILL|TRACKING`, with closed-sum
  filters (`client_kill_filter`) and typed tracking options
  (`client_tracking_on` + REDIRECT / PREFIX / BCAST / OPTIN /
  OPTOUT / NOLOOP).
- **Functions + FCALL**: `FUNCTION LOAD|DELETE|FLUSH|LIST`,
  `FCALL`, `FCALL_RO` (fan-out to every primary for LOAD-class
  commands via `fan_primaries_unanimous`).
- **Cluster introspection**: `CLUSTER KEYSLOT`, `CLUSTER INFO`.
- **Observability**: `LATENCY DOCTOR|RESET`, `MEMORY USAGE`,
  `MEMORY PURGE`.
- `Named_commands` — register command and transaction templates
  with `$N` placeholders, run by name later. Thread-safe; shares
  the same routing as `Client.custom`.
- `Pubsub` — standalone client-level pub/sub with auto-resubscribe
  after reconnect via `Connection.on_connected`.
- `Cluster_pubsub` — regular + sharded pub/sub on one handle, with
  a watchdog fiber re-pinning sharded connections on failover
  (integration test forces all 3 primaries to restart and asserts
  delivery resumes).
- `Transaction` — `MULTI`/`EXEC`/`WATCH`/`DISCARD` with a
  `hint_key` to pin to a slot, and a `with_transaction` scope
  helper.
- `Command_spec` — ~230 entries covering all typed wrappers, plus
  a test that cross-checks every entry against live `COMMAND INFO`
  metadata.
- Send-path optimisation — new `Resp3_writer.command_to_cstruct`
  produces a single allocation of the exact wire size with one
  blit per argument. SET 16 KiB went from 47 % to 91 % of the C
  reference.
- Parser hardening — `Resp3_parser` now rejects negative bulk
  and aggregate lengths (regression found by the parser fuzzer on
  its first run).

### Added — Phase 0 (core)

- Connection layer: auto-reconnect with jittered backoff,
  byte-budget backpressure, circuit breaker (always-on generous
  default), app-level keepalive fiber, TLS (self-signed + system
  CAs), optional cross-domain split (`?domain_mgr`) moving socket
  I/O to a dedicated OS thread.
- RESP3 parser + writer covering all 14 wire types. Streamed
  aggregates raise explicitly (not silently mis-decoded).
- Client layer: abstract `Client.t` with typed commands covering
  strings, counters, TTL, hashes, hash field TTL (Valkey 9+),
  sets, lists, sorted sets, scripting with `Script.t` and
  transparent `NOSCRIPT` fallback, iteration, streams
  (non-blocking + consumer groups), blocking commands.
- Typed variants for every wire-level keyword set (`set_cond`,
  `set_ttl`, `hexpire_cond`, `hgetex_ttl`, `hsetex_ttl`,
  `score_bound`, `value_type`, …) and every per-field status code
  (`field_ttl_set`, `field_persist`, `expiry_state`).
- Routing interface (`Read_from`, `Target`) — surfaces the API
  shape the cluster router plugs into without changing callers.
