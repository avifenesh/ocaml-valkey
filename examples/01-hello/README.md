# 01-hello — basic single-instance usage

Four small programs demonstrating the most common patterns. All
target a local Valkey on `localhost:6379`:

```bash
docker compose up -d
```

## Programs

| File | Demonstrates |
|---|---|
| [basic.ml](basic.ml) | `connect`, SET / GET / INCR, TTL on SET, three reply shapes |
| [hashes.ml](hashes.ml) | `HSET`, `HGET`, `HGETALL`, **per-field TTL** (Valkey 9+) |
| [streams.ml](streams.ml) | `XADD`, `XLEN`, `XRANGE` replay, `XREAD` cursor positioning |
| [streams_groups.ml](streams_groups.ml) | Producer + 2-worker consumer-group split |

## Run

```bash
dune exec examples/01-hello/basic.exe
dune exec examples/01-hello/hashes.exe
dune exec examples/01-hello/streams.exe
dune exec examples/01-hello/streams_groups.exe
```

## Things to notice

- Every command returns `result` — pattern-match on `Ok` / `Error`.
- `Ok None` for missing keys vs `Error _` for failures: two
  distinct outcomes.
- Stream consumer groups: each worker gets its own `Client.t`.
  The exclusive-connection rule for blocking commands also
  applies to stream workers in general (see
  [docs/troubleshooting.md](../../docs/troubleshooting.md)).
- Per-field TTL on hashes is a Valkey 9 feature — won't work on
  Redis 7 or older Valkey.
