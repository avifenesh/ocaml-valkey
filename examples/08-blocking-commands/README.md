# 08-blocking-commands — BRPOP worker

Producer LPUSHes 5 jobs, one every 500 ms. Worker BRPOPs with a
1 s server-side block; when the queue is empty the BRPOP returns
`Ok None` and the worker loops to wait again.

```bash
docker compose up -d
dune exec examples/08-blocking-commands/main.exe
```

Expected output (interleaved):

```
[worker]   BRPOP server-side timeout, retrying
[producer] pushed job-0 (queue len now 1)
[worker]   got job-0
[producer] pushed job-1 (queue len now 1)
[worker]   got job-1
...
[worker]   processed 5 jobs, exiting
```

## The dedicated-client rule

While `worker_client` is parked inside `BRPOP`, that connection
can't service any other command. If `producer_client` and
`worker_client` were the same `Client.t`, the producer's `LPUSH`
would queue behind the BRPOP and you'd deadlock.

Same rule applies to:
- `BLPOP`, `BRPOP`, `BLMOVE`
- `XREAD ... BLOCK`, `XREADGROUP ... BLOCK`
- Subscribe-mode connections (`Pubsub`, `Cluster_pubsub`)
- Transactions (`MULTI`/`EXEC` blocks pin a connection)

For each of those, open a dedicated `Client.t`. The cost is a
TCP connection per blocking worker — cheap.

## Knobs

- `~block_seconds:0.0` blocks forever. Pair with `?timeout` (the
  per-call client timeout) or cancel the switch to escape.
- `~block_seconds:5.0` waits up to 5 s. `Ok None` on timeout.
- `~keys:[k1; k2; k3]` watches multiple lists; the first one to
  have data wins. In cluster mode all keys must hash to the same
  slot.
