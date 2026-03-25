#!/usr/bin/env bash
# Cron usage example (run as the non-root SSH user; no chown needed):
# 0 */12 * * * bash /srv/compose/openclaw_backup.sh sync
#
# Snapshot mode example (daily at 02:30):
# 30 2 * * * bash /srv/compose/openclaw_backup.sh snapshot
#
# Test schedule (every hour at minute 31):
# 31 * * * * bash /srv/compose/openclaw_backup.sh sync

set -euo pipefail
umask 077

PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
RCLONE_BIN="$(command -v rclone || true)"
if [[ -z "$RCLONE_BIN" ]]; then
  echo "[${HOSTNAME:-host}] rclone not found in PATH" >&2
  exit 127
fi

if [[ -z "${HOME:-}" ]]; then
  HOME="$(getent passwd "$(id -un)" | cut -d: -f6)"
  export HOME
fi

DEFAULTS_FILE="/srv/compose/ops_defaults.env"
if [[ -f "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
else
  echo "ERROR: ${DEFAULTS_FILE} not found. Run Step 2 to render ops defaults." >&2
  exit 1
fi

RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-bd}"
OPENCLAW_RCLONE_PATH_PREFIX="${OPENCLAW_RCLONE_PATH_PREFIX:-}"
if [[ -z "$OPENCLAW_RCLONE_PATH_PREFIX" ]]; then
  echo "ERROR: OPENCLAW_RCLONE_PATH_PREFIX is empty. Set it in ansible/vars.yml and re-run Step 2." >&2
  exit 1
fi
OPENCLAW_RCLONE_PATH_PREFIX="${OPENCLAW_RCLONE_PATH_PREFIX%/}"
REMOTE="${RCLONE_REMOTE_NAME}:${OPENCLAW_RCLONE_PATH_PREFIX}"
BACKUP_MODE="${1:-${OPENCLAW_BACKUP_MODE:-sync}}"
SYNC_GUARD_THRESHOLD="${OPENCLAW_SYNC_GUARD_THRESHOLD:-5}"
RCLONE_RETRIES="${OPENCLAW_RCLONE_RETRIES:-5}"
RCLONE_LOW_LEVEL_RETRIES="${OPENCLAW_RCLONE_LOW_LEVEL_RETRIES:-10}"
RCLONE_RETRY_SLEEP="${OPENCLAW_RCLONE_RETRY_SLEEP:-10s}"
RCLONE_CONN_TIMEOUT="${OPENCLAW_RCLONE_CONN_TIMEOUT:-15s}"
RCLONE_TIMEOUT="${OPENCLAW_RCLONE_TIMEOUT:-2m}"
RCLONE_TRANSFERS="${OPENCLAW_RCLONE_TRANSFERS:-4}"
RCLONE_CHECKERS="${OPENCLAW_RCLONE_CHECKERS:-8}"
RCLONE_USE_FAST_LIST="${OPENCLAW_RCLONE_FAST_LIST:-false}"
RCLONE_LIST_TIMEOUT="${OPENCLAW_RCLONE_LIST_TIMEOUT:-15s}"
LOG_DIR="${OPENCLAW_LOG_DIR:-$HOME/.openclaw/backups}"
LOG_FILE="$LOG_DIR/rclone-backup.log"
LOCK_FILE="$LOG_DIR/rclone-backup.lock"

mkdir -p "$LOG_DIR"

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

BACKUP_MODE="${BACKUP_MODE,,}"
if [[ "$BACKUP_MODE" != "sync" && "$BACKUP_MODE" != "snapshot" ]]; then
  echo "[${HOSTNAME:-host}] invalid backup mode: ${BACKUP_MODE}. Use sync or snapshot." >&2
  exit 2
fi

RUN_TAG="$(date +%Y%m%d-%H%M%S)"
timestamp="$(date -Is)"

RCLONE_FLAGS=(
  "--retries=${RCLONE_RETRIES}"
  "--low-level-retries=${RCLONE_LOW_LEVEL_RETRIES}"
  "--retries-sleep=${RCLONE_RETRY_SLEEP}"
  "--contimeout=${RCLONE_CONN_TIMEOUT}"
  "--timeout=${RCLONE_TIMEOUT}"
  "--transfers=${RCLONE_TRANSFERS}"
  "--checkers=${RCLONE_CHECKERS}"
)
if [[ "${RCLONE_USE_FAST_LIST,,}" == "true" ]]; then
  RCLONE_FLAGS+=(--fast-list)
fi

GUARD_TRIGGERED="false"
GUARD_BACKUP_REMOTE=""

WORKSPACE_EXCLUDES=(
  --exclude ".tmp/**"
  --exclude ".git/**"
  --exclude ".DS_Store"
  --exclude "**/.DS_Store"
)

log() {
  echo "[$(date -Is)] $*"
}

restore_remote_on_error() {
  local code=$?
  if [[ "$GUARD_TRIGGERED" == "true" && -n "$GUARD_BACKUP_REMOTE" ]]; then
    log "ERROR: backup failed; attempting to restore remote from ${GUARD_BACKUP_REMOTE}"
    "$RCLONE_BIN" purge "$REMOTE" "${RCLONE_FLAGS[@]}" >/dev/null 2>&1 || true
    if "$RCLONE_BIN" moveto "$GUARD_BACKUP_REMOTE" "$REMOTE" "${RCLONE_FLAGS[@]}"; then
      log "Rollback complete: restored ${REMOTE}"
    else
      log "Rollback failed: manual restore needed from ${GUARD_BACKUP_REMOTE}"
    fi
  fi
  exit "$code"
}

trap restore_remote_on_error ERR

count_local_files() {
  local src="$1"
  local kind="$2"
  if [[ ! -d "$src" ]]; then
    echo 0
    return 0
  fi

  if [[ "$kind" == "workspace" ]]; then
    find "$src" \
      \( -path "$src/.git" -o -path "$src/.git/*" -o -path "$src/.tmp" -o -path "$src/.tmp/*" \) -prune -o \
      -type f ! -name ".DS_Store" -print | wc -l | tr -d ' '
  else
    find "$src" -type f -print | wc -l | tr -d ' '
  fi
}

count_local_total_current_set() {
  local total=0
  local workspace_count credentials_count agents_count telegram_count discord_count

  workspace_count="$(count_local_files "$HOME/.openclaw/workspace" "workspace")"
  credentials_count="$(count_local_files "$HOME/.openclaw/credentials" "credentials")"
  agents_count="$(count_local_files "$HOME/.openclaw/agents" "agents")"
  telegram_count="$(count_local_files "$HOME/.openclaw/telegram" "telegram")"
  discord_count="$(count_local_files "$HOME/.openclaw/discord" "discord")"

  total=$((workspace_count + credentials_count + agents_count + telegram_count + discord_count))
  if [[ -f "$HOME/.openclaw/openclaw.json" ]]; then
    total=$((total + 1))
  fi

  echo "$total"
}

count_remote_total_current_set() {
  local output=""
  local flags=(
    --recursive
    --files-only
    --exclude "before-*/**"
    --exclude "snapshot-*/**"
  )

  if command -v timeout >/dev/null 2>&1; then
    if ! output="$(timeout "$RCLONE_LIST_TIMEOUT" "$RCLONE_BIN" lsf "$REMOTE" "${flags[@]}" "${RCLONE_FLAGS[@]}" 2>/dev/null)"; then
      log "ERROR: failed to list remote files for guard check (timeout=${RCLONE_LIST_TIMEOUT})"
      return 1
    fi
  elif ! output="$("$RCLONE_BIN" lsf "$REMOTE" "${flags[@]}" "${RCLONE_FLAGS[@]}" 2>/dev/null)"; then
    log "ERROR: failed to list remote files for guard check"
    return 1
  fi

  if [[ -z "$output" ]]; then
    echo 0
  else
    printf '%s\n' "$output" | wc -l | tr -d ' '
  fi
}

guard_remote_root_before_sync() {
  local local_count remote_count delta backup_remote backup_name backup_base backup_parent

  local_count="$(count_local_total_current_set)"
  if ! remote_count="$(count_remote_total_current_set)"; then
    log "ERROR: cannot determine remote file count, aborting sync to avoid unsafe overwrite"
    return 1
  fi
  delta=$((remote_count - local_count))

  if (( delta > SYNC_GUARD_THRESHOLD )); then
    backup_base="${OPENCLAW_RCLONE_PATH_PREFIX##*/}"
    backup_name="before-${RUN_TAG}-${backup_base}"
    if [[ "$OPENCLAW_RCLONE_PATH_PREFIX" == */* ]]; then
      backup_parent="${OPENCLAW_RCLONE_PATH_PREFIX%/*}"
      backup_remote="${RCLONE_REMOTE_NAME}:${backup_parent}/${backup_name}"
    else
      backup_remote="${RCLONE_REMOTE_NAME}:${backup_name}"
    fi

    log "Guard triggered (root): local=${local_count}, remote=${remote_count}, delta=${delta} > ${SYNC_GUARD_THRESHOLD}"
    log "Moving remote '${REMOTE}' -> '${backup_remote}' before sync"
    GUARD_TRIGGERED="true"
    GUARD_BACKUP_REMOTE="$backup_remote"
    "$RCLONE_BIN" moveto "$REMOTE" "$backup_remote" "${RCLONE_FLAGS[@]}"
  fi
}

copy_dir() {
  local src="$1"
  local remote_dir="$2"
  shift 2 || true
  local extra=("$@")

  if [[ ! -d "$src" ]]; then
    log "Skip missing directory: $src"
    return 0
  fi

  "$RCLONE_BIN" copy "$src" "$remote_dir" --create-empty-src-dirs "${extra[@]}" "${RCLONE_FLAGS[@]}"
}

snapshot_dir() {
  local src="$1"
  local remote_dir="$2"
  shift 2 || true
  local extra=("$@")

  if [[ ! -d "$src" ]]; then
    log "Skip missing directory: $src"
    return 0
  fi

  "$RCLONE_BIN" copy "$src" "$remote_dir" --create-empty-src-dirs "${extra[@]}" "${RCLONE_FLAGS[@]}"
}

copy_file_if_exists() {
  local src="$1"
  local remote_file="$2"
  if [[ ! -f "$src" ]]; then
    log "Skip missing file: $src"
    return 0
  fi
  "$RCLONE_BIN" copyto "$src" "$remote_file" "${RCLONE_FLAGS[@]}"
}

{
  log "Backup start mode=${BACKUP_MODE} remote=${REMOTE}"

  "$RCLONE_BIN" config show "$RCLONE_REMOTE_NAME" >/dev/null 2>&1 || {
    log "ERROR: rclone remote '${RCLONE_REMOTE_NAME}' not found"
    exit 1
  }

  if [[ "$BACKUP_MODE" == "snapshot" ]]; then
    SNAPSHOT_REMOTE="${REMOTE}/snapshot-${RUN_TAG}"
    log "Snapshot destination: ${SNAPSHOT_REMOTE}"
    snapshot_dir "$HOME/.openclaw/workspace" "${SNAPSHOT_REMOTE}/workspace" "${WORKSPACE_EXCLUDES[@]}"
    copy_file_if_exists "$HOME/.openclaw/openclaw.json" "${SNAPSHOT_REMOTE}/openclaw.json"
    snapshot_dir "$HOME/.openclaw/credentials" "${SNAPSHOT_REMOTE}/credentials"
    snapshot_dir "$HOME/.openclaw/agents" "${SNAPSHOT_REMOTE}/agents"
    snapshot_dir "$HOME/.openclaw/telegram" "${SNAPSHOT_REMOTE}/telegram"
    snapshot_dir "$HOME/.openclaw/discord" "${SNAPSHOT_REMOTE}/discord"
  else
    guard_remote_root_before_sync
    copy_dir "$HOME/.openclaw/workspace" "${REMOTE}/workspace" "${WORKSPACE_EXCLUDES[@]}"
    copy_file_if_exists "$HOME/.openclaw/openclaw.json" "${REMOTE}/openclaw.json"
    copy_dir "$HOME/.openclaw/credentials" "${REMOTE}/credentials"
    copy_dir "$HOME/.openclaw/agents" "${REMOTE}/agents"
    copy_dir "$HOME/.openclaw/telegram" "${REMOTE}/telegram"
    copy_dir "$HOME/.openclaw/discord" "${REMOTE}/discord"
  fi

  log "Backup done"
} >> "$LOG_FILE" 2>&1
