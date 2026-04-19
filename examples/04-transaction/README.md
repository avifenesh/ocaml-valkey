# 04-transaction — WATCH-based optimistic concurrency

Two writers race to update the same balance under WATCH. Whichever
commits first wins; the other sees `Ok None` from `exec` and
retries.

```bash
docker compose up -d
dune exec examples/04-transaction/main.exe
```

Expected output (the order of who-wins-first will vary):

```
[alice] attempt 1: read 100, will write 125
[bob]   attempt 1: read 100, will write 150
[alice] committed!
[bob]   WATCH abort, retrying
[bob]   attempt 2: read 125, will write 175
[bob]   committed!

final balance: 175 (expected 175)
```

## Things to notice

- Each writer uses its **own** `Client.t`. Transactions pin a
  connection from the client's pool; sharing a client between
  fibers running concurrent transactions corrupts both. See
  [docs/transactions.md](../../docs/transactions.md).
- `Tx.with_transaction` is the convenience wrapper —
  `begin_` → `f tx` → `exec`. If `f` raises, it `discard`s before
  re-raising.
- The retry loop is bounded (5 attempts here). Don't retry on
  `Error _` — only on `Ok None`. A transport error means the
  outcome is unknown and a blind retry could double-apply.
