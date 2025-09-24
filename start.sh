#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

ANALYZER_CONF_FILE="${ANALYZER_CONF_FILE:-/opt/presidio/analyzer-config.yml}"
NLP_CONF_FILE="${NLP_CONF_FILE:-/opt/presidio/nlp.yaml}"
RECOGNIZER_REGISTRY_CONF_FILE="${RECOGNIZER_REGISTRY_CONF_FILE:-/opt/presidio/recognizers.yaml}"
ANALYZER_PORT="${PRESIDIO_ANALYZER_PORT:-5002}"
ANONYMIZER_PORT="${PRESIDIO_ANONYMIZER_PORT:-5001}"
POLLY_DIR="/opt/polly"

POLLY_PID=""
ANALYZER_PID=""
ANONYMIZER_PID=""

terminate() {
  log "Stopping services..."
  for pid in "${POLLY_PID}" "${ANALYZER_PID}" "${ANONYMIZER_PID}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
}

cleanup() {
  for pid in "${ANALYZER_PID}" "${ANONYMIZER_PID}"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
}

wait_for_service() {
  local name="$1"
  local port="$2"
  for attempt in $(seq 1 60); do
    if curl -sSf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
      log "$name is ready on port $port"
      return 0
    fi
    sleep 1
  done
  log "ERROR: $name did not become ready on port $port"
  return 1
}

trap terminate INT TERM HUP
trap cleanup EXIT

log "Starting Presidio analyzer (port ${ANALYZER_PORT})"
PORT="${ANALYZER_PORT}" \
ANALYZER_CONF_FILE="${ANALYZER_CONF_FILE}" \
NLP_CONF_FILE="${NLP_CONF_FILE}" \
RECOGNIZER_REGISTRY_CONF_FILE="${RECOGNIZER_REGISTRY_CONF_FILE}" \
python /opt/presidio/analyzer_server.py &
ANALYZER_PID=$!

if ! wait_for_service "Presidio analyzer" "${ANALYZER_PORT}"; then
  terminate
  exit 1
fi

log "Starting Presidio anonymizer (port ${ANONYMIZER_PORT})"
PORT="${ANONYMIZER_PORT}" \
python /opt/presidio/anonymizer_server.py &
ANONYMIZER_PID=$!

if ! wait_for_service "Presidio anonymizer" "${ANONYMIZER_PORT}"; then
  terminate
  exit 1
fi

log "Starting Polly server (port ${PORT:-8081})"
cd "$POLLY_DIR"
node polly.js &
POLLY_PID=$!

set +e
wait "$POLLY_PID"
POLLY_STATUS=$?
set -e

log "Polly server exited with status $POLLY_STATUS"
terminate
exit "$POLLY_STATUS"
