# ocaml-valkey — project memory

A modern Valkey client for OCaml 5 + Eio, RESP3-native, no legacy baggage.

Owner: Avi (Valkey org member, main maintainer of Valkey GLIDE).
Status: Day 1 — learning OCaml, deciding connection-management model.

## Why this exists

Existing OCaml Redis clients (notably `ocaml-redis`) are Lwt/Async-era, RESP2-only, and predate Valkey's modern feature set. The goal here is a small, modern, focused client that targets *only* current OCaml (5.3+) and current Valkey (7.2+), and deliberately drops legacy surface area.

## Rules

### 1. Love of software first
We do this for the love of software and fun. All other considerations are secondary, **except** when other people's businesses or feelings are involved — then that becomes the primary value and we re-assess.

### 2. We own everything — no dismissals
Never describe an issue as "pre-existing," "out of scope," "minor," or "skippable." Everything in this repo is ours. If we find a bug, dead code, bad doc, flaky test, or sloppy error path — we fix it or clearly track it for fixing. We take responsibility.

### 3. Learning pace, not production pace (early sessions)
Every new OCaml, Eio, or ecosystem concept is explained before it's used. Pace is deliberately slow so Avi actually learns and enjoys the language. Small working snippets over grand designs. No "just trust me" code.

## Scope

**In:**
- OCaml 5.3+ only
- Eio-native concurrency (effects-based)
- RESP3 protocol only
- Valkey 7.2+ features: hash field TTL, functions, streams w/ consumer groups, CLIENT NO-EVICT / TRACKING
- Cluster with automatic topology refresh (MOVED/ASK)
- Pipelining + connection pool as first-class

**Out:**
- RESP2, Redis <7, Valkey <7.2
- Lwt, Async backends
- Sentinel
- Blocking-connection APIs
- Legacy `EVAL` ergonomics (lead with Functions)

## Open architectural questions

- Connection model: single connection vs pool vs cluster-aware router (pending Eio study).
- Picos substrate vs Eio direct.
- Typed command/reply via GADTs.

## Conventions

_To be filled in as we learn and decide together._
