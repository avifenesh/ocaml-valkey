# valkey-ocaml

A modern Valkey client for OCaml 5 + [Eio](https://github.com/ocaml-multicore/eio).

**Status: early development.** Foundations and core typed command surface are in; transactions, pub/sub, and cluster are still to come.

## Why

Existing OCaml Redis clients predate Valkey, target RESP2, and use Lwt or Async. This project targets the current era of both stacks:

- **OCaml 5.3+**, Eio-native (effects-based, direct style)
- **RESP3 only** — no RESP2 fallback
- **Valkey 7.2+**, with first-class support for Valkey 8/9 features (HELLO `availability_zone`, `SET IFEQ`, `DELIFEQ`, hash field TTL)

No Lwt compat layer. No legacy Redis support.

## Features

**Connection layer (production-shaped):**
- Auto-reconnect with configurable backoff + jitter
- Byte-budget backpressure (not count-based)
- Circuit breaker (always on, conservative default)
- App-level keepalive fiber
- Full TLS support (self-signed or system CA bundle)
- HELLO / AUTH / SETNAME / SELECT replayed on every reconnect
- Cross-domain split (optional): parser stays on the user's domain; socket I/O runs on a dedicated `Eio.Domain_manager` thread so long parses can't stall the pipeline
- Contracts: user command timeouts honored; commands never silently dropped

**Typed commands (~71):**
Strings, counters, TTL, hashes, hash field TTL (Valkey 9), sets, lists, sorted sets, scripting (including `Script.t` with automatic `EVALSHA` fallback on `NOSCRIPT`), iteration (`SCAN`, `KEYS`), streams (non-blocking + consumer groups), blocking commands (BLPOP / BRPOP / BLMOVE / XREAD BLOCK / WAIT).

**Routing interface:**
- Typed `Read_from` strategies (Primary, Prefer_replica, AZ-affinity variants)
- Routing `Target` types
- Standalone Client ships today; the same API will back the cluster router when it lands

**Not yet shipped:**
- Transactions (MULTI / EXEC / WATCH / DISCARD)
- Pub/sub (SUBSCRIBE / SSUBSCRIBE family)
- Cluster router (slot map, MOVED / ASK retry, topology refresh)
- Benchmarks, fuzzer

See [ROADMAP](#roadmap) below.

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

  (* Typed commands *)
  let _ = Valkey.Client.set client "greeting" "hello" in
  (match Valkey.Client.get client "greeting" with
   | Ok (Some v) -> Printf.printf "got: %s\n" v
   | Ok None     -> print_endline "no value"
   | Error e     ->
       Format.printf "error: %a\n" Valkey.Connection.Error.pp e);

  Valkey.Client.close client
```

### With a dedicated IO domain

Move parser / supervisor to the caller's domain and socket I/O to a separate OS thread, so a CPU-heavy parse on a 16 KiB reply can't freeze the pipeline:

```ocaml
let domain_mgr = Eio.Stdenv.domain_mgr env in
let client = Valkey.Client.connect ~sw ~net ~clock ~domain_mgr
               ~host ~port ()
in
...
```

### With TLS against a managed service

```ocaml
let tls =
  match Valkey.Tls_config.with_system_cas ~server_name:"your.redis.amazonaws.com" () with
  | Ok t -> t
  | Error m -> failwith m
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

# Build and run tests
dune build
dune runtest
```

## Architecture

The Connection layer owns the socket and protocol state machine; the Client layer typed commands and routing.

### Connection states

`Connecting → Alive → (Recovering ⇄ Alive) → Dead`

Recovery replays the full handshake (HELLO + AUTH + SETNAME + SELECT) on every reconnection. In-flight requests stay pending until reconnection succeeds or their command timeout fires. Terminal errors (auth failure, protocol violation, user close) move to `Dead`; everything else is recoverable.

### Cross-domain I/O (optional)

Pass `?domain_mgr` to `Client.connect` to route:
- **Domain A (dedicated)**: `in_pump` reads socket chunks into a `Cstruct.t Eio.Stream.t`; `out_pump` drains the command queue to the socket. Pure syscalls.
- **Domain B (caller)**: parser, supervisor, keepalive, user request fibers. CPU-heavy.

This avoids the cooperative-scheduler pathology where a long RESP3 parse stalls I/O and cascades into a pipeline freeze.

### Blocking commands policy

This client is **multiplexed**. Sending a blocking command (BLPOP, BRPOP, BLMOVE, XREAD BLOCK, WAIT, …) on the Client you use for normal traffic stalls every other fiber sharing that socket.

**Open a dedicated `Client.t` for blocking commands.** The typed blocking API does not auto-switch to an exclusive connection. This is deliberate; matches GLIDE and StackExchange.Redis conventions.

## Roadmap

Next major pieces, roughly in order:

1. **Transactions** — MULTI/EXEC/WATCH/DISCARD with connection pinning under multiplex
2. **Pub/sub** — SUBSCRIBE lifecycle, sharded variants, push dispatch
3. **Cluster router** — slot map, CRC16, MOVED/ASK retry, topology refresh, AZ-aware routing
4. **Benchmarks** — 80/20 GET/SET across 100 B / 1 KiB / 16 KiB at 1 / 10 / 100 concurrency
5. **Fuzzer** — RESP3 parser against arbitrary bytes
6. **Advanced stream admin** — XPENDING, XAUTOCLAIM, XCLAIM, XINFO

## License

MIT. See [LICENSE](LICENSE).
