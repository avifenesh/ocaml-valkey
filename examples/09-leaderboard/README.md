# 09-leaderboard — sorted-set leaderboard

Add players, increment scores as games happen, query the top N
and a score range.

```bash
docker compose up -d
dune exec examples/09-leaderboard/main.exe
```

Expected output:

```
-- top 5 --
  1. carol    110
  2. bob      105
  3. ada      125    ← actually rank changes per inputs; check yours
  ...

bob is rank 1 (0-based)

-- 80..110 (inclusive) --
  bob
  carol
  eve

total players: 6
```

## Sorted-set primitives used

| Command       | Use                                                  |
|---------------|------------------------------------------------------|
| `ZADD`        | Add or update (player, score)                        |
| `ZINCRBY`     | Atomic increment by delta                            |
| `ZRANGE REV`  | Top-N (highest scores first)                         |
| `ZREVRANK`    | A player's rank (0-based)                            |
| `ZRANGEBYSCORE` | All players in a score range                       |
| `ZCARD`       | Total count                                          |

## Why two APIs in this example

This library currently has typed wrappers for `ZRANGE`,
`ZRANGEBYSCORE`, `ZREMRANGEBYSCORE`, and `ZCARD`. The other
sorted-set commands (`ZADD`, `ZINCRBY`, `ZRANK`, `ZSCORE`) go
through `Client.custom` for now — adding typed wrappers is on
the to-do list.

`Client.custom` always works:

```ocaml
match C.custom client [| "ZINCRBY"; board; "10"; "ada" |] with
| Ok (Valkey.Resp3.Bulk_string new_score) -> ...
| Error e -> ...
```

The reply needs decoding by hand. Typed wrappers do that for you.

## Pagination

For pagination over a large board, combine `ZRANGE` with offset
and limit, or use `ZRANGEBYSCORE WITHSCORES LIMIT offset count`.
Custom-command path:

```ocaml
C.custom client
  [| "ZRANGE"; board; "0"; "-1"; "REV"; "WITHSCORES";
     "LIMIT"; string_of_int offset; string_of_int page_size |]
```
