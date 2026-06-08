#!/usr/bin/env bash
set -euo pipefail

# Simulate ChirpStack alert conditions by generating Prometheus counter increments:
# - Communication failure rate too high: make gRPC requests return non-OK (Unauthenticated).
#
# Requirements (one of the following):
# - Option A (recommended): `grpcurl` installed on the host running this script
# - Option B: `docker` available (script will run `grpcurl` via a container)
#
# And:
# - ChirpStack is reachable on the target address you pass (default: 127.0.0.1:8080)
# - Prometheus scraping the ChirpStack /metrics endpoint that exposes api_requests_handled_total
#
# Notes:
# - This script does NOT change any DB/UI settings. It only generates traffic/errors.
# - It uses containers for tools (grpcurl) and (optionally) mosquitto_pub.

DURATION_SECONDS="${DURATION_SECONDS:-420}"  # default 7 minutes (matches typical 5m alert for + buffer)
RATE_PER_SEC="${RATE_PER_SEC:-5}"           # messages/requests per second (best-effort)

TARGET="${TARGET:-127.0.0.1:8080}" # ChirpStack gRPC endpoint (host:port)

usage() {
  cat <<'EOF'
Usage:
  ./leedarson/service/scripts/simulate_comm_alerts.sh --api [--target host:port] [--seconds N] [--rate N]

Env overrides:
  DURATION_SECONDS=420              (default: 420)
  RATE_PER_SEC=5                    (default: 5)
  TARGET=127.0.0.1:8080             (default: 127.0.0.1:8080)

Examples:
  ./.../simulate_comm_alerts.sh --api
  ./.../simulate_comm_alerts.sh --api --seconds 600 --rate 20
EOF
}

log() { printf "[%s] %s\n" "$(date '+%F %T')" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "missing command: $1"; }

preflight_grpc_tool() {
  if command -v grpcurl >/dev/null 2>&1; then
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    return
  fi
  die "need either 'grpcurl' installed locally or 'docker' (not found). Install grpcurl or run on a host with docker."
}

grpcurl_run() {
  # Prefer local grpcurl. Fall back to docker if available.
  if command -v grpcurl >/dev/null 2>&1; then
    grpcurl "$@"
    return
  fi
  if command -v docker >/dev/null 2>&1; then
    # Use reflection; ChirpStack enables tonic reflection (see chirpstack/src/api/mod.rs).
    docker run --rm fullstorydev/grpcurl:latest "$@"
    return
  fi
  die "need either 'grpcurl' installed locally or 'docker' to run grpcurl container"
}

simulate_api_comm_failure_rate() {
  log "Simulating gRPC non-OK ratio (Unauthenticated) for ${DURATION_SECONDS}s at ~${RATE_PER_SEC}/s"
  local end=$((SECONDS + DURATION_SECONDS))

  local target="$TARGET"

  # Pick a simple method; it exists in ChirpStack API and requires auth, so it should return Unauthenticated.
  # If your API package name differs, we auto-discover one method from reflection.
  local method="api.InternalService/GetVersion"
  if ! grpcurl_run -plaintext "$target" list api.InternalService >/dev/null 2>&1; then
    # Try to find any service that ends with InternalService
    local svc
    svc="$(grpcurl_run -plaintext "$target" list 2>/dev/null | grep -E 'InternalService$' | head -n1 || true)"
    if [[ -z "$svc" ]]; then
      die "grpc reflection did not list InternalService; cannot generate gRPC non-OK safely"
    fi
    method="${svc}/GetVersion"
  fi

  while (( SECONDS < end )); do
    # Burst RATE_PER_SEC calls then sleep ~1s.
    local i
    for ((i=0; i<RATE_PER_SEC; i++)); do
      # Empty request body; expected to fail auth and return grpc-status != 0.
      grpcurl_run -plaintext -d '{}' "$target" "$method" >/dev/null 2>&1 || true
    done
    sleep 1
  done
  log "API error simulation done"
}

main() {
  need_cmd bash
  preflight_grpc_tool

  local do_api=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0;;
      --api) do_api=true; shift;;
      --target) TARGET="${2:?}"; shift 2;;
      --seconds) DURATION_SECONDS="${2:?}"; shift 2;;
      --rate) RATE_PER_SEC="${2:?}"; shift 2;;
      *) die "unknown arg: $1";;
    esac
  done

  if ! $do_api; then
    usage
    exit 2
  fi

  log "TARGET=$TARGET DURATION_SECONDS=$DURATION_SECONDS RATE_PER_SEC=$RATE_PER_SEC"

  simulate_api_comm_failure_rate

  log "All selected simulations completed"
}

main "$@"

