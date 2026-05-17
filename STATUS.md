# Project status and next steps

**Snapshot taken:** 2026-05-17, `main` after Phase 11 module support.

This document captures what's shipped on `main`, what's immediately
runnable, the test posture, and what's queued next. v0.3.1 is live
on opam. v0.4.0 is prepared as the module-support release: Search,
JSON, and Bloom all have typed wrappers, bundle-backed integration
coverage, and runnable examples. The remaining pre-1.0 work is the
full audit pass over the now-complete public surface.

Canonical references this complements — not replaces:
- [README.md](README.md) — user-facing surface.
- [ROADMAP.md](ROADMAP.md) — phased plan, preserves the original planning
  text. Use it for intent, not current state.
- [CHANGELOG.md](CHANGELOG.md) — per-release line of what shipped.
- [docs/client-side-caching.md](docs/client-side-caching.md) — ground truth
  for Phase 8's shape; updated at each step.

---

## 1. Published release baseline

**`valkey.0.3.1`** is live on opam. It superseded `0.3.0` with
the opam-sandbox fixture fix for mTLS tests; `0.4.0` is the next
prepared release and adds the Valkey Bundle module surface.

The baseline through 0.2.0, from [CHANGELOG.md](CHANGELOG.md):

- Standalone + cluster client, RESP3-only, OCaml 5.3+/Eio-native.
- Atomic + scatter-gather `Batch` with `WATCH` guards, cross-slot helpers
  (`mget_cluster`, `mset_cluster`, `del_cluster`, `unlink_cluster`,
  `exists_cluster`, `touch_cluster`, `pfcount_cluster`).
- `Transaction` is a thin fa&ccedil;ade over atomic `Batch`.
- Pub/Sub standalone + cluster-aware with failover replay.
- Named commands (user-registered command/transaction templates).
- 240+ tests; parser fuzzer; stability fuzzer; pre-push gate;
  Ubuntu × OCaml {5.3, 5.4} + macOS subset CI; 60% coverage floor;
  nightly 200M-input parser fuzz + 15-min cluster chaos.

## 2. Landed after 0.2.0

### Phase 2.5 — security audit pass (commits `f0e771e..2d281db`)

- **`connection.ml`**: `wrap_with_tls` catch narrowed from catch-all to
  `Tls_eio.Tls_alert | Tls_eio.Tls_failure | End_of_file | Eio.Io _`.
  Non-TLS logic bugs propagate instead of being mislabelled.
- **`connection.ml`**: `Tcp_refused` / `Dns_failed` / `Tls_failed` error
  payloads no longer carry `Printexc.to_string` of the underlying
  exception (which prints paths, cert bytes, etc.). Replaced with a
  classifier that emits stable short kinds (`peer_closed`, `tls_alert`,
  `tls_failure`, `io_error`, errno text via `Unix.error_message`).
- **OpenTelemetry tracing** wired for the bounded operations:
  `valkey.connect` (TCP + TLS + `HELLO`/`SELECT`),
  `valkey.cluster.discover`, `valkey.cluster.refresh`. Outcomes recorded
  as span attributes. With no exporter configured, span ops are near-no-op
  cheap. Per-command spans intentionally not emitted (volume). Redaction
  invariants enforced in `lib/observability.ml` — no auth credentials, no
  command keys, no command values, no server error message bodies. See
  [docs/observability.md](docs/observability.md).
- **Dependency**: `opentelemetry >= 0.90`.

### `Batch.run_atomic` / `run_with_guard` — MOVED/ASK on EXEC = WATCH abort

Discovered while writing the WATCH+topology-change integration
test (formerly deferred): a slot move between WATCH and EXEC was
leaking as `Error (Server_error EXECABORT)` to the caller, who
couldn't distinguish "topology moved, please retry" from "you
sent a malformed transaction." Fixed:

- `queue_all` now classifies its outcome (`All_queued |
  Topology_changed | Transport_error`); a MOVED/ASK during the
  fill-in-MULTI phase short-circuits with `Topology_changed`.
- Both `run_atomic` and `run_with_guard` map `Topology_changed`
  (and a MOVED/ASK on the EXEC frame itself) to `Ok None`,
  mirroring the WATCH-abort path. The connection is dropped so
  the supervisor reconnects against the fresh topology.

Caller's contract for `Ok None` is unchanged: "retry the
read-modify-write loop." Bad-arity / WRONGTYPE EXECABORTs still
flow through the existing per-command-result array path.

### Phase 8 Branch B — Client-side caching (commits `a28f8a3..595b84a`)

Full server-invalidated client-side caching, standalone and cluster, with
single-flight, invalidation-race safety, TTL safety net, metrics, and
BCAST mode. Standalone-pattern inspiration came from lettuce / rueidis /
redis-py; GLIDE's initial CSC (TTL-only, no invalidation) was rejected as
too weak for a serious OCaml client.

Shipped pieces:

| Step | What | Commit |
|------|------|--------|
| 1 | `Cache` primitive (LRU + byte budget) | `a28f8a3` |
| B1 | `CLIENT TRACKING` handshake on (re)connect | `d6639f1` |
| B2.1+B2.2 | Invalidation parser + invalidator fiber | `91fc704` |
| B2.3+B2.4 | Read-path caching on `Client.get` | `61b89af` |
| B3 | Single-flight + invalidation-race safety | `6d4f48c` |
| B6a | `HGETALL` + `SMEMBERS` coverage | `6ba4564` |
| B6b | `MGET` scatter-gather over cache state | `6b19f1a` |
| B7 | Cluster integration + flush invariants | `3ae246d` |
| B8 | Lifecycle tests (reconnect + live failover) | `664187e` |
| B9 | TTL safety net + `Flush_all` race-close | `5f4bfce` |
| B10a | Cache metrics (atomic counters) | `04acdc2` |
| B10b | BCAST mode | `595b84a` |
| B2.5 | OPTIN — pipelined per-read tracking | (this commit) |

Behavioural summary, honest:

- **Cacheable**: `GET`, `HGETALL`, `SMEMBERS`, `MGET`.
- **Not cached by design**: `HGET` / `HMGET` (compound key + prefix-evict
  needed; redis-py shipped it with a field-collision bug — #3612),
  `EXISTS` / `STRLEN` / `TYPE` (low value; covered by the GET-shaped
  entry for the same key in practice).
- **`mode = Default`** is the default and recommended mode for
  standalone and cluster. **`mode = Optin`** is supported on
  both standalone and cluster — the read path pipelines `CLIENT
  CACHING YES + read` as one wire-atomic submit via the new
  internal `Connection.request_pair`, threaded through
  `Router.pair` so the cluster path retries the whole pair on
  the new owner if MOVED arrives on the read frame (frame 1
  stays adjacent to frame 2). The previous `optin : bool` field
  is folded into the `mode` variant so OPTIN/BCAST mutual
  exclusion is encoded in the type.
- Per-shard tracking on cluster happens automatically via the single
  `Client_cache.t` threaded into every shard `Connection.Config`.
- **Flush on topology refresh** and **flush on every per-connection
  reconnect** are both wired — coarse but correct.
- **TTL safety net** off by default; caller sets
  `Client_cache.make ~cache ~entry_ttl_ms:60_000 ()` to opt in.
- **`Flush_all` in-flight race** closed via `Inflight.mark_all_dirty`.
- **Metrics**: `hits`, `misses`, `evicts_budget`, `evicts_ttl`,
  `invalidations`, `puts` via `Client.cache_metrics`.
- **BCAST mode**: `Client_cache.mode = Bcast { prefixes }` activates
  prefix-subscription tracking; server-side rejects overlapping prefixes
  and we surface that as a handshake error (no client-side pre-check yet).

See [docs/client-side-caching.md](docs/client-side-caching.md) for the
full step-by-step.

---

## 3. Test posture

Current release-prep gates:

- `EIO_BACKEND=posix dune runtest` — pure units, no server
  dependency. The v0.4.0 prep run passed 238 tests.
- `EIO_BACKEND=posix dune exec test/run_tests.exe` — live
  standalone, cluster, and Valkey Bundle integration suite. The
  v0.4.0 prep run passed 391 tests with `VALKEY_SEARCH_PORT=6381`,
  `VALKEY_JSON_PORT=6381`, and `VALKEY_BLOOM_PORT=6381`.
- `opam lint valkey.opam` validates the generated package file.
- `EIO_BACKEND=posix opam exec -- dune build -p valkey @install
  @runtest` validates the opam package build recipe.
- CI now exercises the full live integration suite with standalone,
  cluster, and Valkey Bundle services in the Linux matrix, in
  addition to the coverage workflow.

The full live run requires:

1. `docker compose up -d` for standalone Valkey.
2. `sudo bash scripts/cluster-hosts-setup.sh` and
   `docker compose -f docker-compose.cluster.yml up -d` for the
   cluster suite.
3. `docker compose -f docker-compose.search.yml up -d` for
   Search, JSON, and Bloom module tests through Valkey Bundle.

---

## 4. Environment

Release validation assumes a normal Linux development host with
opam, Docker Engine/Compose, and the local `/etc/hosts` mappings
installed by `scripts/cluster-hosts-setup.sh`.

---

## 5. Open design questions (noted but not acted on)

These are documented here rather than as stub code or dead TODOs:

1. **Per-key TTL refresh on hit.** Right now a cached entry's TTL
   counts from its last `put`, not its last `get`. Some users expect
   sliding-window TTL; we don't do that. If wanted: add an
   `expires_at` refresh inside `Cache.get`'s hit branch.
2. **BCAST prefix-overlap validation.** The server rejects overlapping
   prefixes and we surface the error; a client-side pre-check would
   give a better error at build time but is not load-bearing.
3. **MGET error semantics when a joiner's owner fails.** If the batched
   MGET fails, every batched-key resolver is resolved with the error
   and the overall result is `Error e` — but the hit group's results
   are discarded. That matches the expected `Client.mget` contract
   (all-or-nothing). If someone wants partial-result semantics we'd
   need a new API.
4. **OOM stress harness.** Deliberately long-running, not worth the
   CI budget until we have a user report.

---

## 6. Next work, ordered by standing value

Note: these are possibilities, not commitments. Re-confirm before
implementing.

### Release and stabilise

- [x] **Release `valkey.0.3.0`** — tag pushed.
      Bundles Phase 9 (blocking pool) and Phase 10 (IAM + mTLS).
      opam PR ([#29825](https://github.com/ocaml/opam-repository/pull/29825))
      superseded by 0.3.1 after @jmid caught the `runtest` sandbox
      failure on mTLS test fixtures.
- [x] **Release `valkey.0.3.1`** — tag pushed; opam PR
      [#29837](https://github.com/ocaml/opam-repository/pull/29837)
      merged on 2026-05-02.
      Patch-only: ships committed self-signed fixtures under
      `test/fixtures/mtls/` so opam-sandbox `runtest` no longer
      depends on `scripts/gen-tls-certs.sh`. Live mTLS integration
      test still reads from `tls/`. `dune-project` regenerated to
      clear v0.3.0 drift in `valkey.opam`.

### Roadmap continuations

- [x] **Phase 9 — Blocking pool** (shipped in 0.3.0). Narrowed
      from the original "connection pool" scope — a general-purpose
      `Client_pool.t` did not beat single-client +
      `connections_per_node` on the bench rig, so it was dropped.
      `Blocking_pool` stays because the multiplexed socket
      fundamentally can't carry `BLPOP`-class commands. Module +
      `Client` wiring + topology hooks + 14-test correctness matrix
      + 1000-caller stress test + docs/blocking-pool.md +
      `Observability.observe_blocking_pool_metrics` bridge. See
      [ROADMAP.md](ROADMAP.md) for the reduced scope and the
      decision record.
- [x] **Phase 10 — IAM + mTLS** (shipped in 0.3.0). Pure-OCaml
      SigV4 signer (`Iam_sigv4`), auto-refresh provider with a
      10-minute fiber (`Iam_provider`), `Connection.Auth` first-class
      hook + `refresh_auth`, `Client.connect_with_iam` /
      `from_router_with_iam` wiring, `Tls_config.with_client_cert`
      mTLS constructor, expanded `docs/security.md` + `docs/tls.md`.
      Byte-exact SigV4 pipeline pinned; integration tests cover
      `refresh_auth` same / bad / rotated-password paths;
      `bin/iam_smoke/` verified end-to-end against ElastiCache for
      Valkey serverless.
- [x] **Phase 11 — Module support.** `Valkey.Search` has landed:
      typed `FT.CREATE` schema builders, `FT.SEARCH`,
      `FT.AGGREGATE`, `FT.INFO`, `FT._LIST`, and `FT.DROPINDEX`,
      plus bundle-backed integration coverage and
      `examples/11-search/`. `Valkey.Json` has landed for
      production JSON commands including `JSON.MSET`, object, array,
      string, and number mutations, `JSON.FORGET`, `JSON.CLEAR`, and raw
      `JSON.RESP`, with pure tests, bundle-backed integration
      coverage, and `examples/12-json/`. `Valkey.Bloom` has landed
      for `BF.RESERVE`, `BF.ADD`, `BF.MADD`, `BF.EXISTS`,
      `BF.MEXISTS`, `BF.INSERT`, `BF.CARD`, `BF.INFO`, and
      `BF.LOAD`, with pure tests, bundle-backed integration
      coverage, and `examples/13-bloom/`. Per-module opam package
      or a single `valkey-modules` meta can be revisited later; the
      release-prep decision is to keep wrappers in the core package
      for v0.4.0.
- [ ] **Phase 12 — Full audit pass.** Before 1.0.

### CSC follow-ups (optional)

- [x] **OTel bridge for `cache_metrics`.** Shipped — see
      `Valkey.Observability.observe_cache_metrics`.
- [x] **OPTIN ASK redirect retry.** Shipped — `Connection.request_triple`
      drives `CLIENT CACHING YES + ASKING + read` as one wire-adjacent
      submit; `Cluster_router.make_pair`'s ASK arm wires it. Frame
      ordering is load-bearing — the server's `ASKING` flag is
      consumed by the very next command on the connection regardless
      of what it is, so `ASKING` must sit immediately before the
      slot-keyed read.
- [x] **Slot-migration stress test.** Shipped —
      `test/test_csc_optin_migration.ml` drives a real
      `CLUSTER SETSLOT MIGRATING / IMPORTING` window, plants a key on
      the importing target, and exercises the OPTIN ASK retry. The
      25-fiber concurrent variant proves wire-adjacency under
      contention. Cleanup unconditionally clears migration state via
      `CLUSTER SETSLOT … STABLE` so partial runs can't leave the
      cluster broken.

---

## 7. Quick-reference commit landmarks

- Phase 2.5 start: `6086039` (`connection: stop leaking internals via Printexc.to_string`).
- Phase 2.5 close: `2d281db` (`changelog: tighten Phase 2.5 security audit summary`).
- CSC foundation: `a28f8a3` (`cache: bounded LRU+byte-budget primitive`).
- CSC end-to-end working (single-key GET): `61b89af`.
- CSC race-safe: `6d4f48c`.
- CSC all commands: `6b19f1a`.
- CSC cluster + lifecycle: `3ae246d` and `664187e`.
- CSC BCAST landed: `595b84a`.
- CSC OPTIN standalone: `80563ec` (B2.5).
- CSC OPTIN cluster: `d16e0dd` (Router.pair + redirect-aware retry).
- Cluster-router topology-stale-on-MOVED + WATCH+EXEC fixes:
  `a7e8912`, `9cc5c63`.
- Simplify pass on Phase 8: `6cb6efe` (topology stale-ref bug,
  drop dead `Read_from`, tighten OPTIN target fallback,
  `client_caching_yes` constant, comment trim).

Use `git log --grep='Phase 8'` or `git log --grep='csc:'` to walk the
series.
