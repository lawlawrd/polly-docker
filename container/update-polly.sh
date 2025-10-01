#!/usr/bin/env bash
set -euo pipefail

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

log() {
  printf '%s %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*"
}

LOCK_FILE="/tmp/polly_update.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "Update process already running; exiting"
  exit 0
fi

POLLY_DIR="/opt/polly"
POLLY_PID_FILE="/tmp/polly.pid"
RESTART_FLAG="/tmp/polly_restart_requested"

if [[ ! -d "${POLLY_DIR}/.git" ]]; then
  log "Git repository not found at ${POLLY_DIR}; skipping update"
  exit 0
fi

BRANCH="${POLLY_GIT_REF:-}"
if [[ -z "${BRANCH}" ]]; then
  BRANCH="$(git -C "${POLLY_DIR}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo master)"
fi

REMOTE_REF="origin/${BRANCH}"

log "Fetching updates for ${REMOTE_REF}"
if ! git -C "${POLLY_DIR}" fetch --quiet --prune origin; then
  log "git fetch failed"
  exit 1
fi

LOCAL_SHA="$(git -C "${POLLY_DIR}" rev-parse HEAD)"
REMOTE_SHA="$(git -C "${POLLY_DIR}" rev-parse "${REMOTE_REF}" 2>/dev/null || git -C "${POLLY_DIR}" rev-parse "${BRANCH}" 2>/dev/null || true)"

if [[ -z "${REMOTE_SHA}" ]]; then
  log "Unable to resolve remote ref ${REMOTE_REF}; skipping update"
  exit 0
fi

if [[ "${LOCAL_SHA}" == "${REMOTE_SHA}" ]]; then
  log "No updates detected"
  exit 0
fi

log "Updates found; resetting to ${REMOTE_SHA}"
git -C "${POLLY_DIR}" reset --hard "${REMOTE_SHA}"

if [[ -f "${POLLY_DIR}/package-lock.json" ]]; then
  log "Running npm ci"
  npm --prefix "${POLLY_DIR}" ci
else
  log "Running npm install"
  npm --prefix "${POLLY_DIR}" install --omit=dev
fi

log "Rebuilding application"
npm --prefix "${POLLY_DIR}" run build
log "Pruning dev dependencies"
npm --prefix "${POLLY_DIR}" prune --omit=dev

log "Requesting Polly restart"
touch "${RESTART_FLAG}"

if [[ -f "${POLLY_PID_FILE}" ]]; then
  POLLY_PID="$(cat "${POLLY_PID_FILE}" 2>/dev/null || true)"
  if [[ -n "${POLLY_PID}" ]] && kill -0 "${POLLY_PID}" 2>/dev/null; then
    log "Signalling Polly process ${POLLY_PID} to restart"
    kill -TERM "${POLLY_PID}"
  else
    log "Polly PID file present but process not running"
  fi
else
  log "Polly PID file not found; restart will occur on next launch"
fi
