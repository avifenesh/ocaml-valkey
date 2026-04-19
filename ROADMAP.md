# Roadmap

Living document. What's shipped is in the [README](README.md) and
the git log. This is what's *not yet* shipped, grouped by theme,
roughly ordered by priority within each section.

Legend: 🔥 = blocker for 1.0 / announcement. ⭐ = important. 💡 = nice-to-have.

---

## 1. Feature surface

### Functional

- 🔥 **Client-side caching (`CLIENT TRACKING` + local cache)**. Valkey
  pushes invalidation notifications on the connection; the client
  keeps an LRU of bulk-string replies keyed by key. Huge read-heavy
  win. Integrates with our existing push-message handling.
- 🔥 **Cluster-aware batch commands** — typed `mget`, `mset`, `del`,
  `exists` that split keys by slot, fan out the per-slot requests in
  parallel, and merge results. The server enforces same-slot today;
  our client should do the split transparently.
- ⭐ **Pipelining primitive** — queue many commands, flush once, read
  replies in order. Distinct from `Transaction` (no MULTI, no
  atomicity). Same slot-grouping pass as batch mget/mset in cluster.
- ⭐ **Module support — JSON**. Typed wrappers for `JSON.SET` /
  `GET` / `MGET` / `ARRAPPEND` / `ARRINDEX` / `DEL` / `NUMINCRBY` / etc.
  with RESP3 push-aware reply decoding.
- ⭐ **Module support — Search (RediSearch / Valkey-search)**. `FT.*`
  family. Worth a dedicated `Search` module.
- ⭐ **Module support — Bloom**. `BF.ADD` / `BF.EXISTS` /
  `BF.MEXISTS` / `CF.*` (cuckoo) / `TDIGEST.*` / `TOPK.*` /
  `CMS.*`. Probably one module per filter family.
- ⭐ **Keyspace notifications** as a typed `Pubsub` consumer —
  subscribe to `__keyspace@0__:*` patterns, deliver typed events.
- ⭐ **Stream consumer helper** — a higher-level loop around
  `XREADGROUP BLOCK` with automatic XACK on handler success,
  XCLAIM on stuck entries, configurable DLQ.
- 💡 **Distributed locks (Redlock)** — typed primitive on top of
  `SET NX EX` + Lua-based safe release.
- 💡 **Rate-limiting primitives** — token bucket / sliding window
  built on cached Lua scripts.
- 💡 **RESP3 streaming aggregates** (`$?` / `*?` / `~?` / `%?`).
  Currently the parser raises `Parse_error "streamed X not yet
  implemented"`. Fine for today since the server doesn't actually
  send these unless the client opts in, but closing the gap is a
  correctness item.

### Typed command surface expansion

- ⭐ Round out the long tail so `Client.custom` becomes the exception,
  not the norm: geo family, bitmap family (typed arg builders),
  `COPY` / `DUMP` / `RESTORE`, `CLIENT TRACKING`, `FUNCTION LOAD` /
  `FCALL` typed wrappers, `LATENCY` helpers. Track by usage-frequency
  in real apps — driven by user feedback.
- 💡 Code-generate the command surface + `Command_spec` table from
  `COMMAND INFO` output so new Valkey versions pick up new commands
  automatically. Ambitious; do after 1.0.

---

## 2. Operational & integration

### Authentication & security

- 🔥 **IAM authentication** (AWS ElastiCache for Valkey).
  `HELLO 3 AUTH <user> <iam-token>` with a token provider that
  refreshes via STS SigV4. Single-call provider API so app code
  doesn't care about rotation.
- 🔥 **Password management** — **don't ever store secrets in scripts
  or test fixtures**. Replace the `"pass"` literal in the cluster-
  hosts setup script with a proper pattern: read from environment,
  stdin, or a secret provider at call time. Audit the repo for any
  hardcoded credentials (`grep -i 'pass\|secret\|token'`).
- ⭐ **Mutual TLS** (client certs). Today we verify server CAs;
  add an API to present a client cert + key for mTLS enrolments.
- 💡 ACL user rotation helpers (stretch — most apps set it at
  deploy time).

### Pooling

- 🔥 **Connection pool / client pool**. Today each `Client.t` owns
  one multiplexed socket. At the ceiling (one socket saturating a
  CPU), users want N sockets round-robin'd. A `Client_pool.t` that
  wraps N `Client.t`s with a pick strategy (least-loaded, random,
  sticky-by-key-hash). Transparent to typed commands.
- ⭐ **Dedicated sub-pool for blocking** — today users are told to
  open a separate `Client.t` for `BLPOP`/`XREAD BLOCK`/transactions.
  A typed `Blocking_pool` that hands out short-lived dedicated
  connections (with cap + wait queue) would make this clean.

### Observability

- 🔥 **OpenTelemetry traces**. Per-command span with attributes
  (command name, key slot, target primary, ok/err). Per-connection
  span for handshake / reconnect cycles. Use
  [ocaml-opentelemetry](https://github.com/imandra-ai/ocaml-opentelemetry).
- ⭐ **Metrics hooks** — first-class callback API on `Client.t`
  (and `Connection.t`):
  - `on_request_start` / `on_request_end` with latency + outcome.
  - `on_state_change : state -> state -> unit` for connection
    state transitions.
  - `on_reconnect`, `on_failover_detected`, `on_moved`, `on_ask`,
    `on_circuit_break`.
  - Users wire these to Prometheus, StatsD, OTel, whatever.
- ⭐ **Built-in logging** via `logs` with a stable event vocabulary.
  Default off; opt-in via `Logs.set_level`.
- ⭐ **Slow-command tap** — per-client threshold that logs any
  command whose latency exceeds the threshold, with command args
  (redacted optionally).
- ⭐ **Health check API**: `val health : t -> [`Ok | `Degraded of string | `Dead of error]`.
  Composes state, circuit breaker, last-error, topology freshness
  into a single readiness signal for liveness/readiness probes.
- 💡 **Runtime introspection**: expose byte-budget usage, queue
  depth, pending count per connection for `/metrics` endpoints.

### Operational UX

- ⭐ **Graceful shutdown** — `Client.shutdown ~timeout t` that stops
  accepting new commands, waits up to `timeout` for in-flight to
  complete, then closes. Different from `close` which just tears
  down immediately.
- ⭐ **Connection lifecycle events** — same hook plane as metrics,
  but user-facing: "I want to know when I'm reconnecting so I can
  pause my worker."

---

## 3. Testing & quality rigor

- 🔥 **Property-based tests** over `Command_spec`: for every
  command with a key-index entry, randomly generate keys, compute
  slots, dispatch against a real cluster, assert no MOVED is
  produced on first dispatch. Catches Command_spec drift.
- 🔥 **Round-trip property tests** for the RESP3 parser + writer:
  `∀ v, parse (encode v) = v` for our whole `Resp3.t` variant. We
  already have an encoder from the parser fuzzer; formalise as
  a proptest.
- 🔥 **Code coverage** — wire up `ppx_bisect` + a coverage report
  in CI, set a floor, track over time.
- ⭐ **CI matrix** — OCaml 5.3 / 5.4, Linux / macOS, with-tls /
  without, with-cluster / standalone-only. GitHub Actions.
- ⭐ **Bench-in-CI** — run a shortened bench on every push, post
  the delta as a PR comment, fail the build if a scenario
  regresses by more than N %.
- ⭐ **Continuous fuzzing** — scheduled GitHub Action that runs the
  parser fuzzer with fresh seeds for 30 minutes nightly, uploads
  any failing seed + stack trace as an artifact.
- ⭐ **Full audit pass** — read every module, flag every `Obj.magic`
  (there's one in `Cluster_pubsub` I know about), every `try _ ->`
  that swallows an exception, every `_ : unit` that ignores a
  result. Either justify or fix.
- ⭐ **Soak test** — the stability fuzzer for 6-12 hours, verify no
  unbounded memory growth, no fd leaks, no fibre count drift.
- 💡 **Formal model for the retry state machine** — the
  MOVED/ASK/CLUSTERDOWN/TRYAGAIN/Interrupted retry loop is subtle.
  A model-checked spec (TLA+ or similar) would lock in the
  invariants.

---

## 4. Release & community

- 🔥 **Opam packaging** — proper `valkey.opam`: description, tags,
  version, dependency constraints. Separate packages for optional
  things: `valkey-tls`, `valkey-search`, `valkey-json` if we go
  micro-package.
- 🔥 **Versioning policy** — semver commitment, deprecation
  window (one minor version before removal), changelog discipline.
- 🔥 **Release process** — signed tags, `CHANGELOG.md` discipline,
  GitHub release with binaries-not-needed-since-source, `opam publish`
  to the opam-repository.
- 🔥 **Announce** — Discuss OCaml, Valkey mailing list, OCaml
  Weekly News, Reddit /r/ocaml, Twitter/X, HN.
- ⭐ **API documentation** — `dune build @doc` → GitHub Pages via
  an odoc generator. Hosted at a stable URL.
- ⭐ **Cookbook / examples** — a `examples/` folder with runnable
  programs:
  1. Caching layer (client-side caching demo).
  2. Worker pool processing a Valkey stream with XREADGROUP.
  3. Distributed lock with Redlock.
  4. Pub/sub fan-out for a multi-instance service.
  5. Cluster migration: point our client at a 1-node cluster,
     reshard while traffic flows, watch the refresh fibre move
     with us.
- ⭐ **FAQ + migration guide from `ocaml-redis`** in `docs/`.
- ⭐ **CONTRIBUTING.md** — how to build, test, fuzz, bench, the
  pre-push gate, the style conventions.
- 💡 **Real-world blog post** after we've used the library for
  something non-trivial — lessons learned, the optimisation work
  in `BENCHMARKS.md`, the chaos-fuzzer story.

---

## 5. Developer experience

- ⭐ **Devcontainer / Docker image** so a new contributor can
  `git clone && devcontainer up && dune runtest` without hunting
  for opam + docker + certs + /etc/hosts.
- ⭐ **Unified test fixtures** — one helper that spins docker
  compose (standalone + cluster), waits for readiness, yields a
  pair of `Client.t`s, tears down. Most test files reimplement
  this today.
- ⭐ **Type-safe command builder DSL** — for advanced users who
  want to construct commands without a `string array`, a combinator
  API `Cmd.(send "HSET" @@ key k @@ pair field value)`. Optional
  — mostly a nicety.
- 💡 **`dune utop` recipe** in the repo — one-liner to drop into a
  REPL with the library loaded and a cluster ready.
- 💡 **VS Code workspace settings** committed in `.vscode/` for
  anyone using Merlin / LSP.

---

## 6. Items already scheduled from earlier sessions

From `project_next_tasks.md` memory — kept here for completeness:

- ✅ Custom command API + full route listing (`Client.custom`,
  `Command_spec`, ~230 entries).
- ✅ Saved/named commands + stored MULTI-EXEC sets
  (`Named_commands`).
- 🔎 Observation: `handle_retries` promotes `Interrupted` and
  `Closed` to retryable today (covered). The earlier "potential
  improvement" is shipped.

---

## Non-goals (to avoid scope drift)

- **RESP2 fallback.** Not happening. We're RESP3-only; the protocol
  is strictly better and Valkey 7.2+ is the target.
- **Lwt or Async bindings.** Eio only. Users who want another
  runtime wrap it themselves.
- **Redis <7 support.** The feature gap is too large and the
  project name is ocaml-valkey.
- **Client-side cluster scan.** Valkey 9.1 ships a native
  cluster-wide SCAN; use that.
- **Re-implementing hiredis.** The benchmark shows we're at 85-96 %
  of C across scenarios; closing the last points would require
  abandoning the Eio fibre pipeline. Not worth it.
