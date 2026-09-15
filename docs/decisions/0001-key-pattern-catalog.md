# 0001 — Redis key-pattern catalog

**Status:** Accepted (per data-layer architecture review, 2026-09-14)
**Context:** The redis layer is the bounded read-through cache and
hot-state store for the data-layer stack. Prior to this ADR there
was no canonical inventory of every key family and where each one
lives (redis-only vs. promoted to postgres vs. projected to
falkordb). This catalog makes the per-family destination
authoritative and unblocks future audits.

See `docs/cache-abstraction.md` for the read/write contract (tenant
prefix, TTL cap, bypass flag, failure semantics) that applies to
every entry below.

## Catalog

Format: `<prefix><family>:<entity-id>[:<sub-key>]`
Prefix default = `$DATA_LAYER_REDIS_PREFIX` (default `dl:`).
TTL cap = `$DATA_LAYER_REDIS_TTL` (default 300s).

| Key family | Example | TTL class | Destination | Notes |
|---|---|---|---|---|
| `tenant:<tenant_id>:meta` | `dl:tenant:acme:meta` | long (1h) | redis-only | Tenant config (display name, feature flags). Source of truth = tenant onboarding system. |
| `tenant:<tenant_id>:user:<user_id>` | `dl:tenant:acme:user:42` | medium (5m) | redis-only | Read-through from postgres `users` table. |
| `session:<session_id>:presence` | `dl:session:<uuid>:presence` | short (30s) | **postgres primary** | Promoted per 0002 audit-grade rule. Primary lives in `session_heartbeats` / `sessions.last_heartbeat_at` (migration 0004). Redis holds recent-only; postgres is audit source. |
| `session:<session_id>:recent_messages` | `dl:session:<uuid>:recent_messages` | short (60s) | **postgres primary** | Promoted. Primary lives in `messages` (migration 0001). Redis is hot tail cache. |
| `tool:<tool_execution_id>:status` | `dl:tool:<uuid>:status` | short (30s) | **postgres primary** | Promoted. Primary lives in `tool_executions` (migration 0001 + 0005). Redis covers in-flight subset only. |
| `tool:<tool_execution_id>:arguments` | `dl:tool:<uuid>:arguments` | short (60s) | **postgres primary** | Promoted. Same source row as above. |
| `idempotency:<scope>:<key>` | `dl:idempotency:tool:abc123` | short (5m) | **postgres primary** | Promoted. Primary in new `idempotency_keys` table (migration 0006). TTL on redis is advisory; vacuum is correctness boundary in postgres. |
| `ratelimit:<scope>:<principal>` | `dl:ratelimit:api:tenant-acme` | very short (10s) | **postgres audit + redis counter** | Deferred per 0002. Primary events in postgres (migration 0007 — deferred); redis holds the rolling counter for hot path. |
| `lock:<scope>:<resource_id>` | `dl:lock:agent:<agent_id>` | very short (10s) | redis-only | Distributed lock token. Never audited; transient by design. |
| `cache:<entity>:<id>` | `dl:cache:project:<uuid>` | bounded (≤300s) | redis-only | Generic read-through cache. Source of truth = postgres. Out of scope of the dual-write ADR. |
| `pubsub:<channel>` | `dl:pubsub:session.heartbeat` | n/a (pub/sub) | redis-only | Publish channel for the `redis_publish_hook`. One-shot, not durable. See adapters 0001. |
| `working:<scope>:<token>` | `dl:working:req:abc123` | short (60s) | redis-only | Request-scoped working blob. Never inspected after request. |
| `counter:<name>` | `dl:counter:active_sessions` | short (30s) | redis-only | Best-effort current counter. Derived, not stored in postgres. |

## Promotion rule

For each row above, the **Destination** column is the rule:

- **redis-only** → never promoted. Lock tokens, pure cache, pub/sub,
  working blobs, current counters all stay here by design.
- **postgres primary** → audit-grade; postgres is source of truth,
  redis is hot cache with advisory TTL. Promotion path:
  1. Migration creates/extends the postgres table.
  2. Adapter writes postgres first.
  3. Adapter writes redis cache + publishes event.
  4. Publish hook projects to falkordb if applicable.
- **postgres audit + redis counter** → like primary, but postgres
  stores audit events while redis serves the hot-path counter.

## TTL classes

| Class | Default TTL | Use |
|---|---|---|
| very short | 10s | lock tokens, rate-limit rolling counters |
| short | 30–60s | presence, in-flight tool status, idempotency cache |
| medium | 5m | user/tenant lookups |
| long | 1h | tenant config |
| bounded | ≤`$DATA_LAYER_REDIS_TTL` | generic read-through cache (TTL cap enforced) |

All TTLs are clamped by `$DATA_LAYER_REDIS_TTL` (default 300s).
Anything asking for longer is silently clamped.

## Failure semantics (per cache-abstraction.md, restated)

- Connection refused → miss; caller falls through to source-of-truth.
- Timeout (>100ms) → miss; caller falls through.
- Other error → miss + structured log.

These semantics are unchanged by this ADR. The promotion rule
**relies on these semantics**: a redis outage cannot cause a
correctness failure because the primary (postgres) is always
authoritative.

## Bypass flag

`$DATA_LAYER_REDIS_ENABLED=false` forces every read to miss and
every write to be skipped (no pub/sub emit). Postgres remains
authoritative. Useful for cache-bypass debugging and load tests.

## See also

- `docs/cache-abstraction.md` — read/write contract.
- `../data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md`
  — the audit-grade rule that this catalog applies.
- `../data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`
  — how writes flow through to redis (and falkordb via the publish
  hook).
- `../data-layer-falkordb/docs/decisions/0002-data-layer-recommendations-handoff.md`
  — parent handoff that named the categories.
