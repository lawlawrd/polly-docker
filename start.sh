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
POLLY_PID_FILE="/tmp/polly.pid"
POLLY_RESTART_FLAG="/tmp/polly_restart_requested"

POLLY_PID=""
ANALYZER_PID=""
ANONYMIZER_PID=""
CRON_PID=""
SHUTDOWN_REQUESTED=0

terminate() {
  SHUTDOWN_REQUESTED=1
  log "Stopping services..."
  for pid in "${POLLY_PID}" "${ANALYZER_PID}" "${ANONYMIZER_PID}" "${CRON_PID}"; do
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
  done
  rm -f "${POLLY_PID_FILE}"
}

cleanup() {
  for pid in "${ANALYZER_PID}" "${ANONYMIZER_PID}" "${CRON_PID}"; do
    if [[ -n "$pid" ]]; then
      wait "$pid" 2>/dev/null || true
    fi
  done
  rm -f "${POLLY_PID_FILE}" "${POLLY_RESTART_FLAG}"
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

start_cron() {
  local cron_bin
  cron_bin="$(command -v cron || true)"
  if [[ -z "${cron_bin}" ]]; then
    log "Cron binary not found; scheduled updates disabled"
    return
  fi
  log "Starting cron daemon for update checks"
  "${cron_bin}" -f &
  CRON_PID=$!
}

start_polly() {
  log "Starting Polly server (port ${PORT:-8081})"
  node polly.js &
  POLLY_PID=$!
  echo "${POLLY_PID}" > "${POLLY_PID_FILE}"
}

run_polly_loop() {
  local status
  while true; do
    start_polly
    set +e
    wait "${POLLY_PID}"
    status=$?
    set -e
    rm -f "${POLLY_PID_FILE}"

    if (( SHUTDOWN_REQUESTED )); then
      log "Polly server stopped with status ${status}"
      return "${status}"
    fi

    if [[ -f "${POLLY_RESTART_FLAG}" ]]; then
      log "Polly restart requested; restarting service"
      rm -f "${POLLY_RESTART_FLAG}"
      continue
    fi

    log "Polly server exited with status ${status}"
    return "${status}"
  done
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

start_cron

cd "${POLLY_DIR}"

set +e
run_polly_loop
POLLY_STATUS=$?
set -e

terminate
exit "${POLLY_STATUS}"
