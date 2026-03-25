#!/usr/bin/env bash
set -euo pipefail

ALIAS_NAME="${1:-${VPS_ALIAS:-${VPS_NAME:-}}}"
COMPOSE_ROOT="${COMPOSE_ROOT:-/srv/compose}"
DATE_TAG="$(date +%y-%m-%d)"
BACKUP_DIR="${HOME}/${ALIAS_NAME}-compose-bp-${DATE_TAG}"
DEFAULTS_FILE="/srv/compose/ops_defaults.env"
if [[ -f "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
fi

RCLONE_REMOTE_NAME="${RCLONE_REMOTE_NAME:-remote}"
BACKUP_RCLONE_PATH_PREFIX="${BACKUP_RCLONE_PATH_PREFIX:-Backups}"
RCLONE_DEST="${RCLONE_REMOTE_NAME}:${BACKUP_RCLONE_PATH_PREFIX}/${ALIAS_NAME}-compose-backup-$(date +%Y%m%d-%H%M)"
RCLONE_LOG_FILE="${HOME}/rclone-backup.log"
SERVICES_STOPPED="no"

[[ -n "$ALIAS_NAME" ]] || { echo "ALIAS_NAME is required (pass VPS_ALIAS as arg)"; exit 1; }

# Keep only one latest local snapshot for this alias.
shopt -s nullglob
for old_dir in "${HOME}/${ALIAS_NAME}-compose-bp-"*; do
  [[ -d "$old_dir" ]] || continue
  rm -rf "$old_dir"
done
shopt -u nullglob

copy_dir_if_exists() {
  local src="$1" rel_dest="$2"
  [[ -d "$src" ]] || return 0
  mkdir -p "${BACKUP_DIR}/${rel_dest}"
  cp -a "${src}/." "${BACKUP_DIR}/${rel_dest}/"
}

copy_file_if_exists() {
  local src="$1" rel_dest="$2"
  [[ -f "$src" ]] || return 0
  mkdir -p "$(dirname "${BACKUP_DIR}/${rel_dest}")"
  cp -a "$src" "${BACKUP_DIR}/${rel_dest}"
}

copy_glob_if_exists() {
  local pattern="$1" rel_dest_dir="$2"
  local files=()
  shopt -s nullglob
  files=($pattern)
  shopt -u nullglob
  [[ "${#files[@]}" -gt 0 ]] || return 0
  if [[ "$rel_dest_dir" == "." ]]; then
    cp -a "${files[@]}" "${BACKUP_DIR}/"
    return 0
  fi
  mkdir -p "${BACKUP_DIR}/${rel_dest_dir}"
  cp -a "${files[@]}" "${BACKUP_DIR}/${rel_dest_dir}/"
}

restore_services() {
  if [[ "$SERVICES_STOPPED" == "yes" ]]; then
    (
      cd "$COMPOSE_ROOT"
      docker compose up -d >/dev/null 2>&1 || true
    )
  fi
}

[[ -d "$COMPOSE_ROOT" ]] || { echo "compose root not found: $COMPOSE_ROOT"; exit 1; }
[[ -f "$COMPOSE_ROOT/compose.yml" ]] || { echo "compose file not found: $COMPOSE_ROOT/compose.yml"; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "docker not found"; exit 1; }
command -v rclone >/dev/null 2>&1 || { echo "rclone not found"; exit 1; }
rclone config show "${RCLONE_REMOTE_NAME}" >/dev/null 2>&1 || { echo "rclone remote '${RCLONE_REMOTE_NAME}' not found"; exit 1; }

mkdir -p "$BACKUP_DIR"

trap restore_services EXIT

(
  cd "$COMPOSE_ROOT"
  docker compose down
)
SERVICES_STOPPED="yes"

# root-level compose files/scripts
copy_file_if_exists "$COMPOSE_ROOT/compose.yml" "compose.yml"
copy_file_if_exists "$COMPOSE_ROOT/.env" ".env"
copy_glob_if_exists "$COMPOSE_ROOT/*.sh" "."

# easyimage: config + i (exclude i/cache)
copy_dir_if_exists "$COMPOSE_ROOT/easyimage/config" "easyimage/config"
if [[ -d "$COMPOSE_ROOT/easyimage/i" ]]; then
  mkdir -p "${BACKUP_DIR}/easyimage/i"
  rsync -a --exclude 'cache/' "$COMPOSE_ROOT/easyimage/i/" "${BACKUP_DIR}/easyimage/i/"
fi

# komari: full data
copy_dir_if_exists "$COMPOSE_ROOT/komari/data" "komari/data"

# caddy: full caddy directory + root caddy files
copy_dir_if_exists "$COMPOSE_ROOT/caddy" "caddy"
copy_file_if_exists "$COMPOSE_ROOT/Caddyfile" "Caddyfile"
copy_file_if_exists "$COMPOSE_ROOT/Caddyfile.template" "Caddyfile.template"
copy_file_if_exists "$COMPOSE_ROOT/XCaddyfile.template" "XCaddyfile.template"

# openlist: config.json + data.db*
copy_file_if_exists "$COMPOSE_ROOT/openlist/data/config.json" "openlist/data/config.json"
copy_glob_if_exists "$COMPOSE_ROOT/openlist/data/data.db*" "openlist/data"

# vaultwarden: config.json, db.sqlite*, attachments, rsa_key*
copy_file_if_exists "$COMPOSE_ROOT/vaultwarden/data/config.json" "vaultwarden/data/config.json"
copy_glob_if_exists "$COMPOSE_ROOT/vaultwarden/data/db.sqlite*" "vaultwarden/data"
copy_dir_if_exists "$COMPOSE_ROOT/vaultwarden/data/attachments" "vaultwarden/data/attachments"
copy_glob_if_exists "$COMPOSE_ROOT/vaultwarden/data/rsa_key*" "vaultwarden/data"

# cliproxyapi: auths + config.yaml
copy_dir_if_exists "$COMPOSE_ROOT/cliproxyapi/auths" "cliproxyapi/auths"
copy_file_if_exists "$COMPOSE_ROOT/cliproxyapi/config.yaml" "cliproxyapi/config.yaml"

# sub-store: root.json + sub-store.json
copy_file_if_exists "$COMPOSE_ROOT/sub-store/data/root.json" "sub-store/data/root.json"
copy_file_if_exists "$COMPOSE_ROOT/sub-store/data/sub-store.json" "sub-store/data/sub-store.json"

(
  cd "$COMPOSE_ROOT"
  docker compose up -d
)
SERVICES_STOPPED="no"

rclone copy "$BACKUP_DIR" "$RCLONE_DEST" --exclude='*.log' >> "$RCLONE_LOG_FILE" 2>&1
echo "Backup completed: $BACKUP_DIR"
