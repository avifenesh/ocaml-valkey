# 06-distributed-lock

Single-instance lock using `SET NX EX` for acquisition and a tiny
EVAL script for compare-and-delete release.

```bash
docker compose up -d
dune exec examples/06-distributed-lock/main.exe
```

Expected output (the loser depends on Eio scheduling):

```
[alice] trying to acquire lock
[bob]   trying to acquire lock
[alice] acquired with fence 12345-1750435200.123-67890
[alice] critical section complete
[alice] released cleanly
[bob]   acquired with fence 12345-1750435200.625-...
[bob]   critical section complete
[bob]   released cleanly
```

## The pattern

```ocaml
(* acquire *)
match C.set client lock_key fence
        ~cond:C.Set_nx ~ttl:(C.Set_ex_seconds 5) with
| Ok true -> got_it
| Ok false -> someone_else_holds_it

(* release: only delete if the value matches the fence *)
let lua = "if redis.call('GET', KEYS[1]) == ARGV[1] \
           then return redis.call('DEL', KEYS[1]) else return 0 end"
let _ = C.custom client [| "EVAL"; lua; "1"; lock_key; fence |]
```

The fence prevents a stale holder (whose lock has expired and
been re-acquired by someone else) from accidentally releasing
the new owner's lock.

## What this is not

- **Not Redlock.** Redlock acquires the same lock on N independent
  Valkey nodes for tolerance to single-node failure. This
  primitive trusts one node — if that node loses its
  not-yet-replicated state, two callers can briefly both think
  they hold the lock. For production-critical sections, study
  the Redlock spec and implement carefully.
- **Not lease renewal.** A real worker that holds the lock longer
  than `lock_ttl` should periodically `EXPIRE` the lock to extend
  it (the "watchdog" pattern). Otherwise the TTL fires and a
  competitor steals the lock mid-work.
- **Not "fencing" in the Martin Kleppmann sense.** True fencing
  needs the protected resource (a database, an external API) to
  reject older fence tokens. The fence here only proves
  ownership at release time.

For most app-level "don't run this job twice in 30 seconds"
needs, this is enough.
