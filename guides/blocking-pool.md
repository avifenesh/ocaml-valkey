# Blocking pool

`Blocking_pool` is a narrow per-node lease pool for Valkey's
intentionally-blocking commands:

- `BLPOP` / `BRPOP` / `BLMPOP`
- `BLMOVE`
- `BZPOPMIN` / `BZPOPMAX`
- `XREAD BLOCK` / `XREADGROUP BLOCK`

The library's normal `Client.t` multiplexes every fiber onto one
socket per node — a FIFO of request frames, answered in order by
a single reader fiber. That design wins for regular traffic (see
[docs/performance.md](performance.md)), but it cannot carry a
command that is *designed* to sleep on the server: the matching
reply never arrives until the block resolves, and every reply
queued behind it on that wire waits too.

The blocking pool sidesteps that by leasing an exclusive
connection for the duration of each blocking call. The leased
conn runs exactly one command, then either returns to the idle
set (on clean completion or clean server-side timeout) or is
closed (on any exception, cancellation, or stale-generation
tag).

## When to use

- You have a worker fiber running `BLPOP` / `BRPOP` / `XREAD
  BLOCK` alongside normal traffic on the same `Client.t`.
- You have many such workers (hundreds to thousands) but don't
  want hundreds of full clients; one `Client.t` with a pool cap
  is the right shape.
- You want a bounded number of "stuck-on-server" conns — the
  pool's `max_per_node` cap gives you that; past the cap,
  callers either block (`` `Block ``) or fail fast
  (`` `Fail_fast ``).

## When NOT to use

- For **non-blocking commands** — use `Client.get` / `Client.set`
  / etc. directly. The pool adds a lease per call; if the command
  wouldn't freeze the multiplex FIFO in the first place, the
  extra connection is pure cost.
- For **`WAIT` / `WAITAOF`** — these are sensitive to *which*
  connection the preceding write landed on, so they can't share
  a pool lease with an unrelated write. Use
  `Client.with_dedicated_conn` + `Client.wait_replicas_on`
  / `Client.wait_aof_on` (a small dedicated one-shot client);
  `Client.wait` / `Client.waitaof` on the multiplexed `Client.t`
  returns `Error (Wait_needs_dedicated_conn _)` by design.
- For **`MULTI`/`EXEC`** — transactions stay on the main
  multiplexed conn, serialised per-primary by the router's
  atomic lock. The pool does not carry `MULTI`/`EXEC`.

## Opt in

The feature is off by default — `blocking_pool.max_per_node = 0`.
A call to `Client.blpop` on a default client returns
`Error (Pool Pool_not_configured)`.

Opt in through `Client.Config.blocking_pool`:

```ocaml
module BP = Valkey.Blocking_pool

let client =
  let config =
    { Valkey.Client.Config.default with
      blocking_pool =
        { BP.Config.default with
          max_per_node = 16;      (* cap per node *)
          on_exhaustion = `Block; (* wait instead of failing *)
          borrow_timeout = Some 5.0;
        };
    }
  in
  Valkey.Client.connect
    ~sw ~net ~clock ~config
    ~host:"localhost" ~port:6379 ()

match Valkey.Client.brpop client
        ~keys:["jobs"] ~block_seconds:10.0
with
| Ok (Some (_q, job)) -> handle job
| Ok None -> (* server-side timeout *) ()
| Error e ->
    Format.eprintf "brpop: %a@." Valkey.Client.pp_blocking_error e
```

A runnable demo lives at
[examples/08-blocking-commands/](../examples/08-blocking-commands/).

## Config knobs

| Field | Default | Meaning |
|---|---|---|
| `max_per_node` | `0` | Upper bound on conns per node. `0` disables the pool entirely — any blocking call returns `Error (Pool Pool_not_configured)`. |
| `min_idle_per_node` | `0` | Pre-warm count. `0` is lazy-first-use. Pre-warming hides handshake latency at the cost of idle conns. |
| `borrow_timeout` | `Some 5.0` | Wall-clock cap on waiting for an available conn when the pool is at `max_per_node` capacity. `None` waits forever. |
| `on_exhaustion` | `` `Fail_fast `` | `` `Block `` waits up to `borrow_timeout` for a free slot; `` `Fail_fast `` returns `Pool_exhausted` immediately. |
| `max_idle_age` | `Some 300.0` | Close idle conns older than this many seconds. `None` keeps conns forever. |

Sizing guidance: start with `max_per_node` equal to the number
of concurrent blocking workers you expect. If workers are
occasionally bursty but mostly idle, leave `min_idle_per_node`
at 0. Pre-warming (`min_idle_per_node > 0`) is only worth it
for latency-sensitive wake-ups where the TCP + `HELLO`
handshake is noticeable.

## Typed errors

`Client.blpop` / `brpop` / `blmove` / `xread_block` all return
`(_, blocking_error) result`:

| Error | Cause | Caller action |
|---|---|---|
| `Pool Pool_not_configured` | `max_per_node = 0` at `Client.connect` time. | Opt the feature in via `Config.blocking_pool`. |
| `Pool Pool_exhausted` | `` `Fail_fast `` and every conn is in use. | Retry, back off, or raise the cap. |
| `Pool Borrow_timeout` | `` `Block `` but `borrow_timeout` expired before a free slot. | Raise the cap, lower call concurrency, or extend the timeout. |
| `Pool Node_gone` | The node that owned this slot is no longer in topology. | Retry — the router will have refreshed. |
| `Pool (Connect_failed _)` | A fresh conn had to be opened but its handshake failed. | Same as any connect failure: TLS / DNS / auth hygiene. |
| `Exec _` | A conn was leased and the command reached the wire but returned an error (`WRONGTYPE`, `Server_error`, `Closed`, `Protocol_violation`, ...). The leased conn is closed (dirty). | Inspect `Connection.Error.t`. |
| `No_primary_for_slot _` | Router couldn't resolve a primary. | Retry after topology refresh. |
| `Cross_slot _` | Multi-key blocking command where keys hash to different slots in cluster. | Use hashtags to co-locate the keys. |
| `Wait_needs_dedicated_conn _` | You called `Client.wait` / `waitaof` on the multiplexed client. | Use `Client.with_dedicated_conn` + `wait_replicas_on` / `wait_aof_on`. |

## Topology changes

Each borrow is tagged with the node's *generation* at lease
time. The router's topology-refresh fiber fires
`on_node_removed` / `on_node_refreshed` hooks whenever a diff
changes the fleet:

- A node removed from `CLUSTER SHARDS` → bucket drained. Idle
  conns close immediately; new borrows for that node_id return
  `Node_gone`; in-flight leases run to completion and the conn
  is closed on return rather than re-idled.
- A node whose endpoint / role changed but same `node_id` →
  bucket's generation bumps. In-flight leases still complete
  their command, but the conn is closed on return.

Under a plain primary↔replica role-swap failover the node_ids
stay intact, so neither hook fires for the bucket — the pool
transparently routes the next borrow to the new primary's
bucket, and the old bucket ages out via `max_idle_age`.

Wire these up in cluster mode via
`Cluster_router.Config.topology_hooks` —
`Client.topology_hooks_for_pool_ref` builds the exact record the
router expects, closing over a `ref` you set to the pool after
constructing the client.

## Observability

`Blocking_pool.stats` returns an aggregate
`Blocking_pool.Stats.t` with eight counters:

- `in_use`, `idle`, `waiters` — point-in-time gauges.
- `total_borrowed`, `total_created` — cumulative counters.
- `total_closed_dirty` — conns closed because a lease scope
  raised / was cancelled / tagged stale mid-lease. High rate
  signals heavy cancellation or frequent topology churn.
- `total_borrow_timeouts`, `total_exhaustion_rejects` — capacity
  pressure indicators.

`Blocking_pool.stats_by_node` returns the same counters per
`(node_id, Stats.t)` for per-bucket views.

Bridge to OpenTelemetry via `Observability.observe_blocking_pool_metrics`:

```ocaml
let sample_pool () =
  match Valkey.Client.For_testing.blocking_pool client with
  | None -> None
  | Some p ->
      let s = Valkey.Blocking_pool.stats p in
      Some
        { Valkey.Observability.in_use = s.in_use;
          idle = s.idle;
          waiters = s.waiters;
          total_borrowed = s.total_borrowed;
          total_created = s.total_created;
          total_closed_dirty = s.total_closed_dirty;
          total_borrow_timeouts = s.total_borrow_timeouts;
          total_exhaustion_rejects = s.total_exhaustion_rejects;
        }

let () =
  Valkey.Observability.observe_blocking_pool_metrics sample_pool
```

Metrics land under the `valkey.blocking_pool.*` namespace;
`in_use` / `idle` / `waiters` are emitted as non-monotonic sums
(UpDownCounter), the five `total_*` counters as cumulative
monotonic sums. See [docs/observability.md](observability.md)
for exporter setup.

## Gotchas

- Pool conns **never enable `CLIENT TRACKING`** — the CSC cache
  runs exclusively on the main multiplexed bundle.
- Pool conns **never carry `MULTI`/`EXEC`**, **OPTIN CSC pair
  submits**, or **ASK-redirect pair/triple submits**. Those are
  load-bearing on frame-adjacency and stay on the main wire.
- A lease handles **exactly one blocking call**. On any raised
  exception or `Eio` cancellation, the conn is closed — the
  wire state of a half-completed blocking command is opaque, so
  it's safer to discard than to reset.
- Cross-slot multi-key blocking in cluster mode is **rejected
  client-side** with `Cross_slot _` before the command ever
  leaves the process; the server would otherwise return
  `CROSSSLOT`.
