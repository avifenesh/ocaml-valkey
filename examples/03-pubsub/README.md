# 03-pubsub — publish + two subscribers

Single-instance pub/sub. Demonstrates the message-variant types
(`Channel`, `Pattern`, `Shard`), running multiple subscribers
side by side, and graceful shutdown via `next_message ~timeout`.

```bash
docker compose up -d
dune exec examples/03-pubsub/main.exe
```

Expected output (interleaved):

```
[pub] event-0 -> 2 subscribers got it
[sub1, channel] event-0 on events:demo
[sub2, pattern events:*] event-0 on events:demo
[pub] event-1 -> 2 subscribers got it
...
[sub1] done.
[sub2] done.
```

## Notes

- Each subscriber needs its **own** `Pubsub.t` — once a
  connection has issued `SUBSCRIBE`, it can't issue regular
  commands. The publisher uses a separate `Client.t`.
- `Pubsub.subscribe` returns once the command is **written**, not
  once the server has acknowledged. The subscription ack arrives
  as a Push frame and is filtered by `next_message` — the
  100 ms sleep before publishing avoids a race where the publish
  fires before the server has registered the subscription.
- Auto-resubscribe across reconnects is handled by the library;
  see [docs/pubsub.md](../../docs/pubsub.md). For a cluster +
  sharded demo, see the integration test in
  [`test/test_cluster.ml`](../../test/test_cluster.ml).
