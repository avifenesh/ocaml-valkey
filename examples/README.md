# Examples

Each subdirectory is a self-contained, runnable program demonstrating
one use case end-to-end. They build under the same dune project as
the library, so `dune build` from the repo root compiles everything.

## Run an example

```bash
docker compose up -d                       # standalone tests need :6379
# or:
docker compose -f docker-compose.cluster.yml up -d  # for cluster examples

dune exec examples/01-hello/basic.exe
```

Each directory has its own `README.md` with the command lines and a
walk-through.

## What's here

| # | Directory | Demonstrates | Server |
|---|---|---|---|
| 01 | `01-hello/` | Strings, counters, hashes, hash field TTL, streams, consumer groups | standalone |
| 02 | `02-cluster/` | Cluster connect, all four `Read_from` modes, TLS to a managed service | cluster (+ TLS) |
| 03 | `03-pubsub/` | Regular + sharded subscribe, auto-resubscribe on reconnect | standalone or cluster |
| 04 | `04-transaction/` | `WATCH` + `MULTI` / `EXEC` retry loop on a balance | standalone |
| 05 | `05-cache-aside/` | Read-through cache layer with hash-field TTL invalidation (Valkey 9+) | standalone |
| 06 | `06-distributed-lock/` | Single-instance lock with `SET NX EX`, fencing token, safe release | standalone |
| 07 | `07-task-queue/` | Producer/worker queue on Streams + consumer groups + claim-stuck | standalone |
| 08 | `08-blocking-commands/` | `BLPOP` worker on a dedicated client, with timeout + cancel | standalone |
| 09 | `09-leaderboard/` | Sorted-set leaderboard with `ZADD` / `ZINCRBY` / `ZRANGEBYSCORE` / pagination | standalone |

## Convention going forward

When a new significant feature lands in the library, add a small
example under `examples/` that exercises it. Examples are real
runnable code — they are the most honest documentation we have for
how the API is *meant* to be used.
