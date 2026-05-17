# 11-search — Valkey Search with the bundle image

Creates a hash index, inserts a few documents, runs a typed
`FT.SEARCH`, then runs a small `FT.AGGREGATE`.

## Run

Search is provided by the Valkey Bundle image, not the plain
`valkey/valkey` image:

```bash
docker compose -f docker-compose.search.yml up -d

dune exec examples/11-search/main.exe
```

The example uses `localhost:6381`, matching
`docker-compose.search.yml`.
