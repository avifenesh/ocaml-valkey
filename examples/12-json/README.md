# 12-json — Valkey JSON with the bundle image

Stores a JSON document with `Valkey.Json`, reads fields back, mutates
arrays, strings, numbers, and booleans, runs `JSON.MSET`/`JSON.MGET`,
and shows the raw `JSON.RESP` view.

## Run

JSON is provided by the Valkey Bundle image, not the plain
`valkey/valkey` image.

```bash
docker compose -f docker-compose.search.yml up -d

dune exec examples/12-json/main.exe
```

The example uses `localhost:6381`, matching
`docker-compose.search.yml`.
