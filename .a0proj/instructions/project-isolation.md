# data-layer-redis — project isolation directive

This file is injected into the Agent Zero system prompt when this project
is active. It captures the workspace contract for the redis submodule.

## Workspace

ACTIVE WORKSPACE: `/a0/usr/projects/data-layer/data-layer-redis`

The workspace owns the redis cache service: server install, tenant-prefix
key isolation, bounded read-through cache, and per-project Agent Zero
metadata.

## Boundary

This project does NOT own:

- Postgres schema → `../data-layer-postgres`
- FalkorDB graph layer → `../data-layer-falkordb`
- Framework adapters → `../data-layer-adapters`
- Umbrella orchestration → `..`

## Required workflow

1. Read `README.md`, `docs/cache-abstraction.md`, and `AGENTS.md` before changing anything.
2. State the intended outcome and affected paths before implementation.
3. Use `/opt/venv-a0/bin/python` for Agent Zero framework checks; `/opt/venv/bin/python` for task checks.
4. Never write real secrets to source-controlled files.

## Cross-project communication

Cross-component wiring goes through the umbrella's `bootstrap redis`
(which delegates to `lib/install.sh`) and through shared env variables in
`.env.example` / `.a0proj/variables.env`. Do not hard-code paths to other
projects.