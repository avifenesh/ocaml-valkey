# 07-task-queue — Streams + consumer groups + XAUTOCLAIM

Producer pushes 10 tasks. Two workers consume:
- `buggy` crashes after processing 3 tasks (without ACKing the
  4th it had pulled).
- `healthy` keeps going.

A **janitor** fiber periodically calls `XAUTOCLAIM` to reassign
entries that have been pending longer than 500 ms. The crashed
worker's stuck task gets reclaimed and ACKed.

```bash
docker compose up -d
dune exec examples/07-task-queue/main.exe
```

Expected output (interleaved):

```
[producer] task-000 -> 1750435200000-0
[buggy]    processing 1750435200000-0 = task-000
[healthy]  processing 1750435200001-0 = task-001
[producer] task-001 -> ...
[buggy]    processing ... task-002
[buggy]    processing ... task-003
[buggy]    simulating crash after 3 tasks
[healthy]  processing ... task-004
...
[janitor] reclaimed 1 stale entries: 1750435200004-0
[healthy]  processing task-005 ... task-009
```

## Why streams over LPUSH/BLPOP

- **Acknowledgement.** Streams have explicit `XACK`. List-based
  queues lose entries if the worker crashes mid-task.
- **Replay.** `XRANGE` lets you re-read history. Lists drop on pop.
- **Multiple consumers per group.** Built into the consumer-group
  primitive. With lists you'd hand-roll partition logic.
- **Pending-entries list (PEL).** The server tracks who's holding
  what; combined with `XPENDING` / `XAUTOCLAIM`, recovering
  from worker crashes is a one-liner.

## Notes

- Each worker owns its own `Client.t`. The exclusive-connection
  rule for blocking commands also applies to long-running stream
  workers.
- `XAUTOCLAIM` cursor: `"0-0"` means "from the start"; the call
  returns a `next_cursor` for pagination. When the next cursor
  comes back as `"0-0"` again, the scan has completed one
  pass — we just keep looping it forever in the demo.
- Real production task queues usually want: a dead-letter list
  for entries claimed N times without ACK (see `delivery_count`
  on `xpending_entry`), exponential back-off on retry, and
  metrics on processing latency. Easy extensions on this skeleton.
