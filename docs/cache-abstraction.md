# Redis cache abstraction

The redis cache layer follows three rules.

## 1. Tenant-prefix key isolation

Every key written to redis is prefixed with the tenant's namespace:

```
<tenant-prefix><key>     e.g. dl:tenant-a:user:42
```

The default prefix is `$DATA_LAYER_REDIS_PREFIX` (default `dl:`). Per-tenant
overrides use `$DATA_LAYER_REDIS_PREFIX_<tenant>`.

Reads strip the prefix on return so consumers see logical key names.

## 2. Bounded TTL

Every cache entry has a TTL capped at `$DATA_LAYER_REDIS_TTL` seconds (default 300).
Calls that ask for longer TTLs are silently clamped — no entry ever lives longer
than the cap. This bounds memory pressure and ensures stale data has a finite
half-life.

## 3. Bypass flag

When `$DATA_LAYER_REDIS_ENABLED=false`, the cache layer reports a miss for every
key and the caller falls through to its source-of-truth. Useful for:

- Cache invalidation storms
- Debugging stale-cache bugs
- Load tests that need to bypass cache

## Failure semantics

- **Connection refused** → reports miss; caller falls through.
- **Timeout (>100ms)** → reports miss; caller falls through.
- **Other redis error** → reports miss + structured log line.

The cache layer never blocks the caller; it always returns within 100ms.
