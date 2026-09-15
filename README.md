# data-layer-redis

Framework-agnostic Redis cache service for the data-layer stack.

This project owns the redis docker container (`az-redis`), the
tenant-prefix key isolation, the bounded read-through cache
contract, and the cache-abstraction docs. It is wired into the
`data-layer` umbrella as a sibling submodule (its own git
repository at `github.com/NovaAI-innovation/data-layer-redis`).

A second redis instance is also in use on this stack — the
redis-server inside `falkordb-test-sandbox` — but it is owned by
`data-layer-falkordb` and serves graph queries only. The two
redis instances do not share keys.

## Deployment (docker)

Redis runs as a docker container on the data-layer host. The
apt install path (`lib/redis.sh`) is a placeholder; the docker
container is the supported deployment.

```bash
# Start az-redis (redis:7.2-alpine) with persistent volume and AOF
docker run -d --name az-redis --restart=unless-stopped \
    -p 0.0.0.0:6380:6379 \
    -v az-redis-data:/data \
    redis:7.2-alpine \
    redis-server --appendonly yes --appendfsync everysec \
                 --maxmemory-policy allkeys-lru

# Wait for ready
until PGPASSWORD=redis-cli -h 127.0.0.1 -p 6380 PING | grep -q PONG; do sleep 1; done

# Apply config (idempotent)
bash lib/install.sh install
```

The container listens on host port 6380 (mapped to container
6379) so it does not collide with `falkordb-test-sandbox`'s
host port 6379. Data persists in the named volume
`az-redis-data`. Stopping and restarting the container
preserves all state.

## Layout

```
data-layer-redis/
├── .a0proj/                           Agent Zero project metadata
├── docs/
│   ├── cache-abstraction.md           bounded read-through cache contract
│   └── decisions/                     append-only ADRs
├── lib/
│   ├── redis.sh                       legacy apt installer (placeholder)
│   └── install.sh                     applier (install | verify | status | reset)
├── tests/smoke.sh                     verify the cache is reachable
├── Dockerfile                         az-redis image build (redis:7.2-alpine + hardened config)
├── redis.conf                         hardened redis config (AOF, lazyfree, allkeys-lru)
├── README.md
├── AGENTS.md
├── .env.example
└── .gitignore
```

## Commands

```bash
# Start az-redis container (see Deployment above)
docker run -d --name az-redis ...

# Apply config (idempotent — re-runs are no-ops)
bash lib/install.sh install

# Verify cache is reachable (PING)
bash lib/install.sh verify

# Show key counts per tenant prefix
bash lib/install.sh status

# Run smoke tests
bash tests/smoke.sh
```

## Environment

- `DATA_LAYER_REDIS_URL` — redis URI
  (default `redis://localhost:6379/0`; the az-redis container
  binds on host 6380, so use `redis://127.0.0.1:6380/0` or
  `redis://<host>:6380/0` for cross-host)
- `DATA_LAYER_REDIS_PREFIX` — default tenant-prefix key
  namespace (default `dl:`)
- `DATA_LAYER_REDIS_ENABLED` — set to `false` to bypass cache
  and force passthrough (default `true`)
- `DATA_LAYER_REDIS_TTL` — bounded TTL in seconds (default 300)

### Container flags

| Flag | Value | Purpose |
|---|---|---|
| `--appendonly` | `yes` | AOF persistence (primary durability) |
| `--appendfsync` | `everysec` | Fsync AOF once per second (durability vs perf) |
| `--maxmemory-policy` | `allkeys-lru` | Evict any key under memory pressure |

The container also exposes a TCP port on `0.0.0.0:6380` so
Tailscale peers and other docker hosts can reach it. For
production, switch to a TLS proxy or set `requirepass` in
`redis.conf` and rebuild the image.

## Status

Deployed and verified (2026-09-14):

- az-redis container running on hermes host 6380, persistent volume
  `az-redis-data`
- PING/SET/GET verified via redis-cli (loopback)
- Cross-host PING/SET/GET verified from local container via redis-py
- `lib/install.sh install|verify` and `tests/smoke.sh` all PASS
- redis-py 8.1.0 installed on /opt/venv and /opt/venv-a0

The `lib/redis.sh` apt installer is a placeholder; `lib/install.sh`
is a config applier that validates reachability via `redis-cli -u
"$DATA_LAYER_REDIS_URL" PING` and reports the tenant prefix. The
container is started and configured at run time; `lib/install.sh`
does not manage the container lifecycle.

## Key pattern catalog

See `docs/decisions/0001-key-pattern-catalog.md` for the canonical
inventory of every redis key family used in the data-layer stack,
its TTL class, and its destination (redis-only / postgres primary /
projected to falkordb). New keys MUST be added to that catalog
before being written in production code.

## Boundary

This project does NOT own:

- Postgres schema → `../data-layer-postgres`
- FalkorDB graph layer → `../data-layer-falkordb`
- Framework adapters → `../data-layer-adapters`
- Umbrella orchestration → `..`

The `redis-server` inside `falkordb-test-sandbox` is owned by
`data-layer-falkordb` and serves graph queries only. Cache keys
(`dl:` prefix) and graph keys are namespaced separately.
