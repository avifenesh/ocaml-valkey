# 05-cache-aside — read-through with hash field TTL

Per-field TTL on a hash key (Valkey 9+) lets you keep one logical
"entity" cached as a single key, with each attribute owning its
own freshness policy.

```bash
docker compose up -d   # Valkey 9 image
dune exec examples/05-cache-aside/main.exe
```

Expected output:

```
first round (all misses, populates the cache):
  [db] computing name for 42
name         ada                                  (MISS)
  [db] computing avatar_url for 42
avatar_url   https://avatars.example/42.png       (MISS)
  [db] computing seen_now for 42
seen_now     1750435200                           (MISS)

second round (everything hits):
name         ada                                  (HIT)
avatar_url   https://avatars.example/42.png       (HIT)
seen_now     1750435200                           (HIT)

fields and their remaining TTLs (-1 = no expiry, -2 = missing):
  name         persistent
  avatar_url   expires in 300 s
  seen_now     expires in 30 s
```

## Why hash field TTL

Without per-field TTL, you have to choose between:

- **One key per field** — easy TTL per attribute, but no atomic
  fetch of the whole entity, and lots of small keys (more memory
  overhead per slot in cluster mode).
- **One hash, no per-field TTL** — atomic fetch via `HGETALL`,
  but you have to cache-bust the whole entity when any field
  expires.

Hash field TTL gives you both: one key per entity, but each field
expires on its own schedule. Set policies per attribute via
`HEXPIRE` (per second) or `HPEXPIRE` (per ms).

## Notes

- Pre-Valkey-9 servers reject `HEXPIRE` with `ERR unknown command`.
  Detect server version via `Client.info` if you need to
  conditionally fall back to per-field keys.
- The "stale" detection in this demo is implicit: `HGET` returns
  `None` for an expired (or never-set) field. If you need to
  distinguish "expired" from "never set", check `HTTL` first or
  store a sentinel.
