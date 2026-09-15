#!/usr/bin/env bash
# data-layer-redis/lib/install.sh
# Idiomatic applier following the data-layer umbrella contract.
# Subcommands: install | verify | status | reset
set -euo pipefail
URL="${DATA_LAYER_REDIS_URL:-redis://localhost:6379/0}"
PREFIX="${DATA_LAYER_REDIS_PREFIX:-dl:}"
TTL="${DATA_LAYER_REDIS_TTL:-300}"
ENABLED="${DATA_LAYER_REDIS_ENABLED:-true}"
log()  { printf '[redis %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
fail() { printf '[redis FAIL] %s\n' "$*" >&2; exit 3; }
usage() { cat <<USAGE
Usage: $0 <install|verify|status|reset>
USAGE
}
run_redis() { redis-cli -u "$URL" "$@" 2>/dev/null; }
case "${1:-help}" in
  install)
    if [[ "$ENABLED" == "false" ]]; then
      log "DATA_LAYER_REDIS_ENABLED=false; cache is bypassed; install skipped"
      exit 0
    fi
    log "tenant prefix: $PREFIX"
    log "TTL cap:       $TTL"
    log "URL:           $URL"
    log "install is a no-op when server is already running and prefix is set"
    log "install complete (placeholder; server install lives in lib/redis.sh)"
    ;;
  verify)
    if [[ "$ENABLED" == "false" ]]; then
      log "DATA_LAYER_REDIS_ENABLED=false; verify skipped"
      exit 0
    fi
    pong=$(run_redis PING || true)
    [[ "$pong" == "PONG" ]] || fail "PING failed against $URL"
    # Surface the live runtime config so a Dockerfile/redis.conf
    # drift is visible at verify time. Config changes baked into
    # redis.conf only take effect on container restart — see
    # docker compose restart redis.
    for cfg in bind protected-mode requirepass; do
      val=$(run_redis CONFIG GET "$cfg" | tail -1 || true)
      log "config $cfg = ${val:-<unset>}"
    done
    log "verify ok"
    ;;
  status)
    if [[ "$ENABLED" == "false" ]]; then
      echo "status: bypassed (DATA_LAYER_REDIS_ENABLED=false)"
      exit 0
    fi
    echo "URL:           $URL"
    echo "tenant prefix: $PREFIX"
    echo "TTL cap:       $TTL"
    keys=$(run_redis --scan --pattern "${PREFIX}*" | wc -l || echo "0")
    echo "keys cached:   $keys"
    ;;
  reset)
    if [[ "$ENABLED" == "false" ]]; then
      log "DATA_LAYER_REDIS_ENABLED=false; reset skipped"
      exit 0
    fi
    log "reset would flush tenant-prefixed keys: ${PREFIX}*"
    run_redis --scan --pattern "${PREFIX}*" | xargs -r -n100 redis-cli -u "$URL" DEL >/dev/null
    log "tenant-prefixed keys cleared"
    ;;
  help|--help|-h|"") usage ;;
  *) echo "unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac
