# 13-bloom — Valkey Bloom filters with the bundle image

Creates Bloom filters with `Valkey.Bloom`, adds items one at a time
and in batches, checks membership, uses `BF.INSERT`, and reads parsed
`BF.INFO` metadata.

## Run

Bloom filters are provided by the Valkey Bundle image, not the plain
`valkey/valkey` image.

```bash
docker compose -f docker-compose.search.yml up -d

dune exec examples/13-bloom/main.exe
```

The example uses `localhost:6381`, matching
`docker-compose.search.yml`.
