# data-layer-redis/Dockerfile
#
# Builds the redis cache service for the data-layer stack.
# Tenant-prefix key isolation, bounded TTL, and bypass flag are
# applied at the application layer (write_through.py);
# this Dockerfile just ships a hardened Valkey 8.x (BSD-3) with
# append-only persistence and a healthcheck.
#
# Image swap rationale (2026-09-16): moved FROM redis:7.2-alpine →
# valkey/valkey:8-alpine. Both are BSD-3-Clause; Valkey is the active
# fork of Redis (BSD-3 lineage retained) and incorporates the
# performance improvements and active development that upstream
# Redis 8.0.6 carries under SSPL/RSALv1. The RESP protocol and
# on-disk RDB/AOF format are wire- and storage-compatible, so
# redis.conf + write_through.py + redis_publish_hook.py require
# no source changes.
#
# Build:   docker build -t data-layer-redis data-layer-redis/
# Run:     docker run -d --name az-redis -p 127.0.0.1:6380:6379 \n#                -v az-redis-data:/data data-layer-redis

FROM valkey/valkey:8-alpine

# Drop default redis config; ship our own.
RUN rm -f /usr/local/etc/redis/redis.conf
COPY redis.conf /usr/local/etc/redis/redis.conf

# Make the data dir writable by redis user (already is in the base image,
# but be explicit so future maintainers don't break it).
RUN chown -R redis:redis /data

# Default port (overridden by docker-compose / run flags when needed).
EXPOSE 6379

# Healthcheck: PING must respond with PONG.
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD redis-cli -p 6379 PING | grep -q PONG || exit 1

# Use the stock redis entrypoint with our config.
CMD ["redis-server", "/usr/local/etc/redis/redis.conf"]