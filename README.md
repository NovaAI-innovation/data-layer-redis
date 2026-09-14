# data-layer-redis

Framework-agnostic Redis cache service for the data-layer stack.

This project owns the redis server install, tenant-prefix key isolation,
bounded read-through cache contract, and the cache-abstraction docs. It
is wired into the `data-layer` umbrella as a sibling submodule (its
own git repository at `github.com/NovaAI-innovation/data-layer-redis`).

## Layout

```
data-layer-redis/
├── .a0proj/                           Agent Zero project metadata
├── docs/
│   ├── cache-abstraction.md           bounded read-through cache contract
│   └── decisions/                     append-only ADRs
├── lib/
│   ├── redis.sh                       redis server install
│   └── install.sh                      applier (install | verify | status | reset)
├── tests/smoke.sh                     verify cache is reachable
├── README.md
├── AGENTS.md
├── .env.example
└── .gitignore
```

## Commands

```bash
# Install redis + start server
sudo bash lib/redis.sh

# Apply tenant-prefix config (idempotent)
bash lib/install.sh install

# Verify cache is reachable (PING + key namespace check)
bash lib/install.sh verify

# Show key counts per tenant prefix
bash lib/install.sh status

# Run smoke tests
bash tests/smoke.sh
```

## Environment

- `DATA_LAYER_REDIS_URL` — redis URI (default `redis://localhost:6379/0`)
- `DATA_LAYER_REDIS_PREFIX` — default tenant-prefix key namespace (default `dl:`)
- `DATA_LAYER_REDIS_ENABLED` — set to `false` to bypass cache and force passthrough (default `true`)
- `PERSISTENCE_REDIS_TTL` — bounded TTL in seconds (default `300`)

## Status

Greenfield scaffold — no server install yet. `lib/redis.sh` is a
placeholder that prints intent; `lib/install.sh` validates
reachability via `redis-cli -u "$DATA_LAYER_REDIS_URL" PING` and sets
the tenant prefix on first install. Production install requires `sudo`
apt for `redis-server` (out of agent scope).