# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Connection layer: auto-reconnect with jittered backoff, byte-budget
  backpressure, circuit breaker (always-on generous default), app-level
  keepalive fiber, TLS (self-signed + system CAs), optional cross-domain
  split (`?domain_mgr`) moving socket I/O to a dedicated OS thread.
- RESP3 parser + writer. All 14 wire types. Streamed aggregates raise
  explicitly (not silently mis-decoded).
- Client layer: abstract `Client.t` with typed commands covering strings,
  counters, TTL, hashes, hash field TTL (Valkey 9+), sets, lists, sorted
  sets, scripting with `Script.t` and transparent `NOSCRIPT` fallback,
  iteration, streams (non-blocking + consumer groups), blocking commands.
- Typed variants for every wire-level keyword set (`set_cond`, `set_ttl`,
  `hexpire_cond`, `hgetex_ttl`, `hsetex_ttl`, `score_bound`, `value_type`,
  …) and every per-field status code (`field_ttl_set`, `field_persist`,
  `expiry_state`).
- Routing interface (`Read_from`, `Target`) — surfaces the API shape the
  cluster router will plug into without changing callers.
- 82 tests, ~3.7 s, alcotest-based. Docker Compose sets up Valkey 9.
