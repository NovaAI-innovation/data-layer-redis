# AGENTS.md — data-layer-redis

Agent contract for the redis submodule of the data-layer stack.

## Scope and ownership

This project is the redis cache service. It owns the server install, the
tenant-prefix key isolation, the bounded read-through cache, and the
cache-abstraction contract. It does NOT own postgres, falkordb, the
framework adapters, or the umbrella orchestration. Those live in sibling
projects.

## Isolation and security

Keep plans, scripts, configs, tests, docs, and evidence inside this
workspace. Do not write real secrets to source-controlled files; use
`.env.example` for placeholders. Do not modify files in `/a0`, the parent
`../data-layer/`, other sibling submodules, global plugins, system
services, or live databases unless the user explicitly requests the
integration and the side effect is reported.

## Required workflow

Before consequential changes, read `README.md`,
`docs/cache-abstraction.md`, `AGENTS.md`,
`.a0proj/instructions/project-isolation.md`. State the intended outcome
and affected paths before implementation. Keep deployment state separate
from source.

## Runtime boundary

Use `/opt/venv-a0/bin/python` for Agent Zero framework and plugin-hook
checks. Use `/opt/venv/bin/python` for task or user-code checks. Do not
treat one runtime as proof of the other.

## Canonical references

- `lib/redis.sh` — redis server install
- `lib/install.sh` — applier (install | verify | status | reset)
- `docs/cache-abstraction.md` — bounded read-through cache contract
- `docs/decisions/` — append-only ADRs