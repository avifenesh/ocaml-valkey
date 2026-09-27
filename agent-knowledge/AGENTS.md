# Agent Knowledge Base

> Learning guides created by /learn. Reference these when answering questions about listed topics.

## Available Topics

| Topic | File | Sources | Depth | Created |
|-------|------|---------|-------|---------|
| AWS ElastiCache IAM Authentication Protocol | elasticache-iam-auth-protocol.md | 18 | medium | 2026-04-28 |
| Connection pool designs in Redis/Valkey clients (and adjacent DB clients) | connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md | 23 | medium | 2026-04-28 |

## Trigger Phrases

Use this knowledge when user asks about:

- "ElastiCache IAM" → elasticache-iam-auth-protocol.md
- "ElastiCache authentication" → elasticache-iam-auth-protocol.md
- "AWS IAM token" → elasticache-iam-auth-protocol.md
- "SigV4 signing for ElastiCache" → elasticache-iam-auth-protocol.md
- "elasticache:Connect" → elasticache-iam-auth-protocol.md
- "presigned URL for Redis" → elasticache-iam-auth-protocol.md
- "IAM authentication Redis" → elasticache-iam-auth-protocol.md
- "IAM authentication Valkey" → elasticache-iam-auth-protocol.md
- "ElastiCache user configuration" → elasticache-iam-auth-protocol.md
- "connection pool" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "connection pooling" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "blocking commands" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "BLPOP" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "BRPOP" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "XREAD BLOCK" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "multiplexing vs pooling" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "connection multiplexing" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "Lettuce pooling" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "redis-py pool" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "Jedis pool" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "pub/sub connection" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "subscribe mode" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "cluster topology" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md
- "MOVED ASK" → connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md

## Quick Lookup

| Keyword | Guide |
|---------|-------|
| ElastiCache, IAM, AWS, SigV4 | elasticache-iam-auth-protocol.md |
| pool, pooling | connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md |
| blocking | connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md |
| multiplex | connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md |
| cluster | connection-pool-designs-in-redisvalkey-clients-and-adjacent-db-c.md |

## How to Use

1. Check if user question matches a topic or trigger phrase
2. Read the relevant guide file from agent-knowledge/
3. Answer based on synthesized knowledge from multiple authoritative sources
4. Cite the guide if user asks for sources or references
5. For source-level details, refer to resources/{slug}-sources.json

## Research Methodology

All guides were created using:
- Progressive query funnel (broad → focused → deep)
- Multi-dimensional source quality scoring (authority, recency, depth, examples, uniqueness)
- Just-in-time content extraction (summaries only, no full-text copying)
- Cross-pollination from adjacent ecosystems (PostgreSQL, MongoDB, etc.)
- Primary source preference (official docs, source code, specifications over tutorials)
