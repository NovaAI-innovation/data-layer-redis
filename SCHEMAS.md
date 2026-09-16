# data-layer-redis — SCHEMAS.md

**Redis is the ephemeral cache layer for the data-layer stack** (per
[`../docs/SUBMODULE_OWNERSHIP.md`](../docs/SUBMODULE_OWNERSHIP.md) boundary rule
#2: *"No shared mutable state between submodules — the only state a submodule may
expose is via its own service (port, schema, key namespace, or HTTP API)."*).
Postgres is the durable source of truth; redis is hot cache / hot state / pub-sub
fan-out only. This document is the key-pattern-level schema spec for every key
family catalogued in `docs/decisions/0001-key-pattern-catalog.md`.

Each key family is documented along the same five dimensions used in
[`../data-layer-postgres/SCHEMAS.md`](../data-layer-postgres/SCHEMAS.md)
(`Purpose` | `Value` | `Retrieval impact` | `Mutation / transformation` |
`Queries enabled`), with three additional identifier columns (`key_pattern` |
`type` | `ttl_s`) because Redis keys are typed strings with a TTL rather than
typed columns in a row.

**Schema authority rule:** if this document conflicts with
`redis.conf` or the lib scripts (`lib/install.sh`, `lib/redis.sh`), the `.sh` and
`redis.conf` win. Update this doc in the same commit that changes the lib or
the config.

---

## Key family inventory (13 families)

| # | Family | Example | TTL class | Destination (per ADR 0001) | Postgres mirror | Notes |
|---|---|---|---|---|---|---|
| 1 | `tenant:<tenant_id>:meta` | `dl:tenant:acme:meta` | long (1h) | redis-only | — | tenant onboarding system is SOT |
| 2 | `tenant:<tenant_id>:user:<user_id>` | `dl:tenant:acme:user:42` | medium (5m) | redis-only | — | read-through from postgres `users` |
| 3 | `session:<session_id>:presence` | `dl:session:<uuid>:presence` | short (30s) | **postgres primary** | `sessions.last_heartbeat_at` + `session_heartbeats` (§11) | promoted per ADR 0002 |
| 4 | `session:<session_id>:recent_messages` | `dl:session:<uuid>:recent_messages` | short (60s) | **postgres primary** | `messages` (§9) | hot tail cache |
| 5 | `tool:<tool_execution_id>:status` | `dl:tool:<uuid>:status` | short (30s) | **postgres primary** | `tool_executions` (§10) | in-flight subset |
| 6 | `tool:<tool_execution_id>:arguments` | `dl:tool:<uuid>:arguments` | short (60s) | **postgres primary** | `tool_executions.arguments` (§10) | same source row |
| 7 | `idempotency:<scope>:<key>` | `dl:idempotency:tool:abc123` | short (5m) | **postgres primary** | `idempotency_keys` (§12) + `tool_executions.idempotency_key` (§10) | TTL on redis is advisory |
| 8 | `ratelimit:<scope>:<principal>` | `dl:ratelimit:api:tenant-acme` | very short (10s) | **postgres audit + redis counter** | `rate_limit_events` (deferred, ADR 0002) | hot path counter |
| 9 | `lock:<scope>:<resource_id>` | `dl:lock:agent:<agent_id>` | very short (10s) | redis-only | — | distributed lock token |
| 10 | `cache:<entity>:<id>` | `dl:cache:project:<uuid>` | bounded (≤`$DATA_LAYER_REDIS_TTL`) | redis-only | — | generic read-through |
| 11 | `pubsub:<channel>` | `dl:pubsub:session.heartbeat` | n/a (pub/sub) | redis-only | — | one-shot, not durable |
| 12 | `working:<scope>:<token>` | `dl:working:req:abc123` | short (60s) | redis-only | — | request-scoped working blob |
| 13 | `counter:<name>` | `dl:counter:active_sessions` | short (30s) | redis-only | — | derived, never stored in postgres |

Prefix default = `$DATA_LAYER_REDIS_PREFIX` (default `dl:`). TTL cap =
`$DATA_LAYER_REDIS_TTL` (default `300s`). Per-tenant overrides use
`$DATA_LAYER_REDIS_PREFIX_<tenant>`.

---

## Per-key-family section

### 1. `tenant:<tenant_id>:meta` (redis-only)

Tenant-level config cache: display name, feature flags, onboarding metadata.
Source of truth is the tenant onboarding system (outside this stack).

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:tenant:<tenant_id>:meta` | string (JSON) | 3600 (long) | Cache of tenant config so the adapter path can resolve tenant context without round-tripping to the onboarding system | JSON blob: `{"display_name", "feature_flags": [...], "region": ...}` | `WriteThrough.from_env()._redis().get(...)` on every adapter dispatch that needs tenant context; `EXISTS` check before re-fetch | `SETEX` with 3600s on first read; `DEL` on tenant config change; falls through to onboarding system on miss | `GET`, `SETEX`, `EXISTS`, `DEL` by exact key (no scan) |

**Loss semantics:** pure cache, miss-on-error. A redis outage degrades to
slow path (re-fetch from onboarding system); no correctness impact. Documented
in `data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md`
under "What stays redis-only".

---

### 2. `tenant:<tenant_id>:user:<user_id>` (redis-only)

Read-through cache for the postgres `users` table. Bounded TTL prevents
long-lived stale identity data.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:tenant:<tenant_id>:user:<user_id>` | string (JSON) | 300 (medium) | Hot path for user lookups (auth, profile rendering) | JSON blob: `{"id", "email", "display_name", "roles": [...]}` | `GET` on auth path; miss triggers postgres `users` read + `SETEX` | `SETEX` on postgres read; `DEL` on user update; no pub/sub emit | `GET`, `SETEX`, `DEL` by exact key; `SCAN --pattern dl:tenant:<tenant_id>:user:*` for tenant-wide invalidation |

**Loss semantics:** pure cache, miss-on-error. Postgres `users` is the SOT;
loss/eviction forces a re-read. No correctness impact.

---

### 3. `session:<session_id>:presence` (postgres primary)

Promoted per ADR 0002. Postgres is the audit source; redis holds the
recent-only subset so presence queries do not stampede the database.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:session:<session_id>:presence` | string (JSON) | 30 (short) | Cache of the latest `record_session_heartbeat()` result so live presence lookups don't hit postgres | JSON blob: `{"session_id", "last_heartbeat_at": ISO8601, "source": "adapter"}` | `GET session:<id>:presence` is the fast path; miss falls through to `record_session_heartbeat()` or postgres `sessions.last_heartbeat_at` | `SETEX` from `WriteThrough.session_heartbeat()` after the postgres insert; `DEL` on session close | `GET`, `SETEX`, `DEL` by exact key; `SCAN --pattern dl:session:*:presence` for sweep |

**Loss semantics:** **no correctness impact.** Postgres is the SOT —
`sessions.last_heartbeat_at` + `session_heartbeats` row is the audit record;
redis loss just forces a postgres re-read. Per ADR 0002: *"redis miss or TTL
expiry must never cause a correctness failure."*

---

### 4. `session:<session_id>:recent_messages` (postgres primary)

Hot tail cache of recent messages for a session. Postgres `messages` (§9
in postgres SCHEMAS.md) is the durable record.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:session:<session_id>:recent_messages` | list (JSON-encoded strings) | 60 (short) | Recent N messages for a session so the UI can render the tail without paging postgres | List of JSON blobs: `[{"id", "role", "content", "created_at"}, ...]` | `LRANGE` to fetch the tail; miss falls through to `SELECT ... FROM messages WHERE session_id = ... ORDER BY created_at DESC LIMIT N` | `RPUSH` (capped via `LTRIM`) after postgres insert; `DEL` on session close or cache eviction | `LRANGE`, `RPUSH`, `LTRIM`, `LLEN`, `DEL`, `EXPIRE` |

**Loss semantics:** **no correctness impact.** All messages are durable in
postgres `messages`. Loss only forces a tail re-fetch.

---

### 5. `tool:<tool_execution_id>:status` (postgres primary)

In-flight subset cache. Postgres `tool_executions.status` is the audit record.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:tool:<tool_execution_id>:status` | string (JSON) | 30 (short) | Hot status of an in-flight tool call so the agent loop can poll without stampeding postgres | JSON blob: `{"id", "status": "pending\|success\|error\|blocked", "attempt_number", "started_at"}` | `GET` from the agent loop on poll; miss falls through to `tool_executions` row | `SETEX` on insert (`status='pending'`) and on each status transition; `DEL` on terminal state plus expiry | `GET`, `SETEX`, `DEL` by exact key |

**Loss semantics:** **no correctness impact.** Postgres `tool_executions`
(§10 in postgres SCHEMAS.md) is the durable record. Loss just forces a
postgres re-read on the next poll.

---

### 6. `tool:<tool_execution_id>:arguments` (postgres primary)

Cached `tool_executions.arguments` JSON so retry chains do not need to
re-derive the input from caller context. Same source row as #5.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:tool:<tool_execution_id>:arguments` | string (JSON) | 60 (short) | Cache of `tool_executions.arguments` JSON for retry/audit consumers | JSON blob (same shape as postgres `arguments` jsonb column) | `GET` on retry path; miss falls through to postgres | `SETEX` on first row insert; `DEL` on row delete (cascade) | `GET`, `SETEX`, `DEL` by exact key |

**Loss semantics:** **no correctness impact.** Arguments are durable in
postgres `tool_executions.arguments`. Loss forces a re-read.

---

### 7. `idempotency:<scope>:<key>` (postgres primary)

Promoted per ADR 0002 + postgres migration 0006. Postgres
`idempotency_keys` (§12 in postgres SCHEMAS.md) is the durable claim log;
redis is an advisory hot cache for the active claim window.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:idempotency:<scope>:<key>` | string (JSON) | 300 (short, advisory) | Cache of the active `idempotency_keys` claim so the adapter can short-circuit duplicate calls without hitting postgres | JSON blob: `{"status": "fresh\|in_progress\|completed\|failed", "response_payload": {...}}` | `GET` on idempotent retry path; miss falls through to `claim_idempotency_key(scope, key, ttl_s)` | `SETEX` on claim; `SETEX` again with new `response_payload` on completion; `DEL` on `failed` or claim expiry | `GET`, `SETEX`, `DEL` by exact key; `EXISTS` for cheap pre-check |

**Loss semantics:** **no correctness impact.** Postgres `idempotency_keys`
is the SOT; `claim_idempotency_key()` uses `SELECT ... FOR UPDATE` so the
redis advisory layer cannot cause double-execution. Per ADR 0002: *"vacuum
is correctness boundary in postgres."*

---

### 8. `ratelimit:<scope>:<principal>` (postgres audit + redis counter)

Promoted per ADR 0002 but deferred. Postgres `rate_limit_events` (not yet
migrated) is the audit source; redis serves the hot-path rolling counter.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:ratelimit:<scope>:<principal>` | string (integer-encoded) | 10 (very short) | Rolling window counter for rate-limit gating on the hot path | Integer counter as string: `"42"` | `INCR` + `EXPIRE` on each request; `GET` to read current count; gate compares against `RATE_LIMIT_*` env | `INCR` (atomic) + `EXPIRE` to set/reset the window; `DEL` on window expiry | `INCR`, `DECR`, `GET`, `EXPIRE`, `TTL`, `DEL` |

**Loss semantics:** **no correctness impact.** Counter loss means a brief
under-count in the rolling window (a few extra requests may slip through
until the next INCR); the audit events in postgres `rate_limit_events`
remain the SOT for billing / abuse review. Acceptable data loss is
documented in ADR 0002.

---

### 9. `lock:<scope>:<resource_id>` (redis-only)

Distributed lock token. Never audited; transient by design.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:lock:<scope>:<resource_id>` | string (UUID) | 10 (very short) | Distributed lock guard: token written with `SET NX EX`; lock holder must release or let TTL expire | UUID token: `"550e8400-e29b-41d4-a716-446655440000"` | `SET key token NX EX 10` to acquire; `DEL` (only if value matches token) to release; `EXISTS` to check | `SET ... NX EX` for acquire; `EVAL` (Lua CAS) for safe release; expiry is automatic | `SET ... NX EX`, `GET`, `DEL`, `EXISTS`, `EXPIRE`, `EVAL` |

**Loss semantics:** transient by design. A redis outage frees all locks,
which may cause a brief contention spike but no correctness impact (lock
acquires are idempotent at the application layer). Documented in ADR 0002
under "What stays redis-only".

---

### 10. `cache:<entity>:<id>` (redis-only)

Generic read-through cache for any postgres-backed entity. The postgres
SOT is always authoritative.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:cache:<entity>:<id>` | string (JSON) | ≤ `$DATA_LAYER_REDIS_TTL` (default 300; bounded) | Generic read-through cache for hot entity reads (projects, agents, sessions, etc.) | JSON blob of the entity row | `GET` on adapter path; miss falls through to postgres and back-fills | `SETEX` clamped at `$DATA_LAYER_REDIS_TTL` regardless of caller request; `DEL` on entity update | `GET`, `SETEX`, `DEL`, `EXISTS`, `TTL`; `SCAN --pattern dl:cache:<entity>:*` for entity-wide invalidation |

**Loss semantics:** pure cache, miss-on-error. Out of scope of the dual-write
ADR (ADR 0001) because there is no application-level event that triggers a
write-through; callers fall through to the postgres SOT and back-fill.

---

### 11. `pubsub:<channel>` (redis-only — pub/sub, not a stored value)

Publish channel for the `redis_publish_hook`. One-shot events; no key is
persisted. Each projection (`session.heartbeat`, `tool.execution`, …) gets
its own channel.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:pubsub:<channel>` | n/a (pub/sub, not stored) | n/a | Fire-and-forget channel used by `WriteThrough.write()` to notify `RedisPublishHook` subscribers | Event payload: `{"projection": "...", "cypher": [...], "params": {...}, "event_id": "<uuid>"}` (JSON) | `SUBSCRIBE` / `PSUBSCRIBE` on the long-lived `RedisPublishHook` side; `PUBLISH` from `WriteThrough.write()` | `PUBLISH` on write; subscribers receive messages via `SUBSCRIBE`/`PSUBSCRIBE` | `PUBLISH`, `SUBSCRIBE`, `PSUBSCRIBE`, `UNSUBSCRIBE`, `PUBSUB CHANNELS`, `PUBSUB NUMSUB` |

**Loss semantics:** fire-and-forget. A missed event is replayed by the next
event for the same record (idempotent MERGEs in falkordb per ADR
`data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`).

---

### 12. `working:<scope>:<token>` (redis-only)

Request-scoped working blob. Never inspected after the request completes.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:working:<scope>:<token>` | string (JSON) | 60 (short) | Transient scratchpad for a single request (intermediate computation, idempotent staging) | JSON blob (opaque, request-defined) | `GET` / `SETEX` within the same request only; no cross-request reads | `SETEX` at request start; `DEL` at request end; TTL acts as the safety net | `GET`, `SETEX`, `DEL`, `EXPIRE` |

**Loss semantics:** acceptable data loss. The working blob is a scratchpad;
its loss aborts the in-flight request, which the caller retries from the
postgres SOT. No audit, no projection, no cross-request state.

---

### 13. `counter:<name>` (redis-only)

Best-effort current counter (active sessions, in-flight tools, queue depth).
Derived, never stored in postgres.

| key_pattern | type | ttl_s | purpose | value | retrieval_impact | mutation | queries_enabled |
|---|---|---|---|---|---|---|---|
| `dl:counter:<name>` | string (integer-encoded) | 30 (short) | Cheap counter for ops dashboards and autoscaling signals | Integer count as string: `"137"` | `GET` on the metrics path; `INCR`/`DECR` from event handlers | `INCR`, `DECR`, `SET`, `GET`, `EXPIRE` | `INCR`, `DECR`, `GET`, `SET`, `EXPIRE`, `TTL` |

**Loss semantics:** acceptable data loss. Counter is derived (rebuilt from
postgres on miss). ADR 0002 lists counters under "What stays redis-only":
*"Current counters (best-effort, derived not stored)."*

---

## Dual-write contract

Per ADR `data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`,
every promoted state category flows through
`data-layer-adapters/lib/write_through.py`:

```
WriteThrough.write(record)
   │
   ├─► INSERT/UPSERT  →  data-layer-postgres (durable)
   ├─► SETEX          →  data-layer-redis (advisory TTL, this namespace)
   └─► PUBLISH        →  dl:pubsub:<channel>
                              │
                              ▼
                       RedisPublishHook (subscribe)
                              │
                              └─► GRAPH.QUERY  →  data-layer-falkordb
```

Failure containment (per ADR 0001):

- **Postgres write failure** → raises; nothing else commits.
- **Redis write failure** → logged, non-fatal; postgres still authoritative;
  the next event for the same record re-projects.
- **Publish failure** → logged, non-fatal; idempotent MERGEs in falkordb
  make replay safe.

### Per-family mirror map

| Redis family | Postgres SOT table.column | Postgres SCHEMAS.md section | Promotion driver |
|---|---|---|---|
| `session:<id>:presence` | `session_heartbeats` (event log) + `sessions.last_heartbeat_at` (rolling marker) | §11 + §8 (`sessions`) | ADR 0002 + migration `0004_session_presence.sql` |
| `session:<id>:recent_messages` | `messages` | §9 (`messages`) | ADR 0002 + migration `0001_init.sql` |
| `tool:<id>:status` | `tool_executions.status` (+ `attempt_number`, `finished_at`) | §10 (`tool_executions`) | ADR 0002 + migration `0005_tool_executions_lifecycle.sql` |
| `tool:<id>:arguments` | `tool_executions.arguments` | §10 (`tool_executions`) | same source row as `tool:<id>:status` |
| `idempotency:<scope>:<key>` | `idempotency_keys` (primary claim log) + `tool_executions.idempotency_key` (correlation) | §12 (`idempotency_keys`) + §10 (`tool_executions.idempotency_key`) | ADR 0002 + migration `0006_idempotency_keys.sql` |
| `ratelimit:<scope>:<principal>` | `rate_limit_events` (deferred — not yet migrated) | not yet in postgres SCHEMAS.md | ADR 0002 deferred |

### Out-of-band cross-link: `emails` (§13 in postgres SCHEMAS.md)

The postgres `emails` table (§13) does **not** mirror to redis per the canonical
catalog (`docs/decisions/0001-key-pattern-catalog.md`); it mirrors to
`data-layer-qdrant` (collection `mpg_emails`, 768-dim cosine). The
`emails.qdrant_point_id` + `emails.qdrant_ingested_y_n` columns are the
explicit postgres↔qdrant contract (see postgres SCHEMAS.md
"Cross-table integrity contracts" #2). The catalog is intentionally silent
on a redis mirror for `emails` because the audit-grade store is qdrant, not
redis.

---

## Pure-ephemeral keys (no postgres mirror)

These families do not appear in any postgres table. Per ADR 0002 they stay
in redis by design because audit, replay, or recovery do not require them:

| Family | Why redis-only | What happens on loss |
|---|---|---|
| `tenant:<id>:meta` | SOT is the tenant onboarding system | fall through to onboarding system |
| `tenant:<id>:user:<id>` | SOT is postgres `users` (not in current migrations) | fall through to postgres `users` |
| `lock:<scope>:<resource_id>` | transient, never audited | lock auto-frees; re-acquire is idempotent |
| `cache:<entity>:<id>` | generic read-through | fall through to postgres SOT |
| `pubsub:<channel>` | fire-and-forget event channel | replayed by next event for same record (idempotent MERGE) |
| `working:<scope>:<token>` | request-scoped scratchpad | request aborts; caller retries from postgres |
| `counter:<name>` | derived, never stored | rebuilt from postgres on miss |

Acceptable data loss for all of the above is documented in ADR
`data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md`
under "What stays redis-only".

---

## Commands

RESP commands issued by the redis lib scripts and the adapter lib, grouped by
client:

### `lib/install.sh` (bash + `redis-cli`)

| Command | Args | Used by subcommand | Purpose |
|---|---|---|---|
| `PING` | — | `verify` | reachability check |
| `CONFIG GET` | `<key>` (bind, protected-mode, requirepass) | `verify` | surface live runtime config |
| `--scan --pattern` | `<prefix>*` | `status`, `reset` | iterate tenant-prefixed keys |
| `DEL` | `<key>...` (batched 100 at a time via `xargs -n100`) | `reset` | purge tenant-prefixed keys |

### `tests/smoke.sh`

| Command | Args | Purpose |
|---|---|---|
| `PING` | — | delegates to `lib/install.sh verify` |

### `data-layer-adapters/lib/write_through.py` (python `redis-py`)

| Command | Args | Purpose |
|---|---|---|
| `SETEX` | `<key> <ttl_s> <value>` | dual-write hot cache after postgres insert; TTL clamped at `DATA_LAYER_REDIS_TTL` (default 300s) |
| `PUBLISH` | `<channel> <payload>` | emit projection hint to `RedisPublishHook` |

### `data-layer-adapters/lib/redis_publish_hook.py` (python `redis-py`)

| Command | Args | Purpose |
|---|---|---|
| `SUBSCRIBE` | `<channel>...` | long-lived subscribe to per-projection channels |
| `PSUBSCRIBE` | `<pattern>...` | pattern-subscribe for projection families |

### Implicit commands used by callers (via `redis-py`)

| Command | Used by | Purpose |
|---|---|---|
| `GET` | `cache:*`, `tenant:*:meta`, `tenant:*:user:*`, `session:*:presence`, `session:*:recent_messages` (via `LRANGE`), `tool:*:status`, `tool:*:arguments`, `idempotency:*`, `working:*`, `counter:*` | primary read |
| `EXISTS` | `idempotency:*` | cheap pre-check before claim |
| `DEL` | all write families | invalidate / delete |
| `EXPIRE` | `ratelimit:*`, `idempotency:*` | refresh TTL without overwriting value |
| `TTL` | `idempotency:*` | check remaining lease |
| `LRANGE` | `session:*:recent_messages` | read tail of recent-messages list |
| `RPUSH` / `LTRIM` / `LLEN` | `session:*:recent_messages` | append + cap list length |
| `INCR` / `DECR` | `ratelimit:*`, `counter:*` | atomic counter mutation |
| `EVAL` (Lua CAS) | `lock:*` | safe release (compare token) |
| `SET ... NX EX` | `lock:*` | atomic acquire with TTL |

### Server-side / config commands

| Command | Source | Purpose |
|---|---|---|
| `redis-cli PING` | `Dockerfile HEALTHCHECK` | container health check |
| `CONFIG GET` | `redis.conf` reader in `verify` | runtime config drift detection |

---

## ACL roles

The `redis.conf` in this submodule **does not define any ACL users or
custom roles** — the server runs with the redis 7.2 default user
(`protected-mode no`, no `requirepass`, no `user ...` directives). The
`maxmemory-policy` is `noeviction` (cache misses → miss-and-fall-through,
not eviction); `notify-keyspace-events` is empty (no key-expired
notifications).

| Setting | Value | Source | Effect |
|---|---|---|---|
| `user` directives | none | `redis.conf` | single default user; no auth required on the docker-internal network |
| `protected-mode` | `no` | `redis.conf` | binds 0.0.0.0; **assumes the container sits behind a docker network or Tailscale mesh** (see `README.md` "Deployment") |
| `requirepass` | unset | `redis.conf` | none — switch to a TLS proxy or set `requirepass` + rebuild image before exposing on a public network |
| `maxmemory-policy` | `noeviction` | `redis.conf` | memory pressure → write rejection, not silent eviction; pairs with the application-layer `DATA_LAYER_REDIS_TTL` cap to bound key age |
| `notify-keyspace-events` | `""` | `redis.conf` | key-expired notifications disabled (extra CPU); flagged as future work if `WriteThrough` or `RedisPublishHook` ever needs them |

**Future work:** for production, add `user <name> on ><password> ~dl:* &* -@dangerous`
to `redis.conf` so the only commands reachable are those scoped to the
tenant-prefixed namespace and the dangerous subcommands (`CONFIG`,
`SHUTDOWN`, `DEBUG`, `KEYS`, etc.) are denied. Until that lands, the
submodule is suitable for the docker-internal / Tailscale-mesh deployment
described in `README.md` only.

---

## Cross-links

- **Boundary contract:** [`../docs/SUBMODULE_OWNERSHIP.md`](../docs/SUBMODULE_OWNERSHIP.md)
  — boundary rule #2 (no shared mutable state between submodules) and the
  `data-layer-redis` row in the per-submodule ownership matrix
  (cache layer for postgres; not SOT for anything).
- **Postgres SOT spec:** [`../data-layer-postgres/SCHEMAS.md`](../data-layer-postgres/SCHEMAS.md)
  — every dual-write reference in §8 (`sessions.last_heartbeat_at`),
  §9 (`messages`), §10 (`tool_executions`), §11 (`session_heartbeats`),
  §12 (`idempotency_keys`). §13 (`emails`) does **not** mirror to redis;
  it mirrors to `data-layer-qdrant`.
- **Audit-grade rule:** [`../data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md`](../data-layer-postgres/docs/decisions/0002-audit-grade-ephemeral-state-promoted-to-postgres.md)
  — the rule this catalog applies: *"If a state category must survive an
  audit, replay, or recovery scenario, postgres is the primary. Redis is
  allowed as a hot cache or working copy, but a redis miss or TTL expiry
  must never cause a correctness failure."*
- **Dual-write wiring:** [`../data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md`](../data-layer-adapters/docs/decisions/0001-dual-write-and-redis-publish-hook.md)
  — interface for `WriteThrough.write()` and `RedisPublishHook.start()`.
- **Adapter lib that issues the commands:** `data-layer-adapters/lib/write_through.py`
  (`SETEX`, `PUBLISH`) and `data-layer-adapters/lib/redis_publish_hook.py`
  (`SUBSCRIBE`, `PSUBSCRIBE`). Cross-referenced from
  `data-layer-adapters/TOOLS_AND_WIRING.md` when produced.
- **Cache abstraction contract:** [`docs/cache-abstraction.md`](cache-abstraction.md)
  — tenant-prefix, bounded TTL, bypass flag, miss-on-error semantics that
  apply to every key family above.
- **Canonical key inventory:** [`docs/decisions/0001-key-pattern-catalog.md`](decisions/0001-key-pattern-catalog.md)
  — the source of truth for the catalog table at the top of this doc.

---

**Schema authority rule (restated):** if this document disagrees with
`redis.conf` or the lib scripts (`lib/install.sh`, `lib/redis.sh`, the
adapter `lib/write_through.py`, `lib/redis_publish_hook.py`), the `.sh`
and `.conf` win. Update this doc in the same commit that updates the
config or the lib.
