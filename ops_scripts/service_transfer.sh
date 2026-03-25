#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash ops_scripts/service_transfer.sh -a <SRC_ALIAS> -b <DST_ALIAS> -s <service1,service2,...> [-c <compose_root>]

Example:
  bash ops_scripts/service_transfer.sh -a vps_a -b vps_b -s "komari,openlist"

Notes:
  - This script runs on your local machine and uses SSH aliases from ~/.ssh/config.
  - It stops selected services on source and destination before transferring data.
  - It backs up destination service folders into ~/<service>-before-transfer-<timestamp>.
EOF
}

SRC_ALIAS=""
DST_ALIAS=""
SERVICE_CSV=""
COMPOSE_ROOT="/srv/compose"

while getopts ":a:b:s:c:h" opt; do
  case "$opt" in
    a) SRC_ALIAS="$OPTARG" ;;
    b) DST_ALIAS="$OPTARG" ;;
    s) SERVICE_CSV="$OPTARG" ;;
    c) COMPOSE_ROOT="$OPTARG" ;;
    h)
      usage
      exit 0
      ;;
    :)
      echo "Missing value for -$OPTARG" >&2
      usage
      exit 1
      ;;
    \?)
      echo "Unknown option: -$OPTARG" >&2
      usage
      exit 1
      ;;
  esac
done

[[ -n "$SRC_ALIAS" && -n "$DST_ALIAS" && -n "$SERVICE_CSV" ]] || {
  usage
  exit 1
}

if [[ "$SRC_ALIAS" == "$DST_ALIAS" ]]; then
  echo "Source and destination aliases must be different." >&2
  exit 1
fi

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

validate_service_name() {
  local name="$1"
  [[ "$name" =~ ^[a-zA-Z0-9._-]+$ ]]
}

declare -a SERVICES=()
IFS=',' read -r -a _raw_services <<< "$SERVICE_CSV"
for raw in "${_raw_services[@]}"; do
  svc="$(trim "$raw")"
  [[ -n "$svc" ]] || continue
  if ! validate_service_name "$svc"; then
    echo "Invalid service name: $svc" >&2
    exit 1
  fi
  SERVICES+=("$svc")
done

[[ "${#SERVICES[@]}" -gt 0 ]] || {
  echo "No valid services parsed from: $SERVICE_CSV" >&2
  exit 1
}

service_args="${SERVICES[*]}"
transfer_tag="$(date +%Y%m%d-%H%M%S)"
local_stage_dir="$PWD/service-transfer-${SRC_ALIAS}-to-${DST_ALIAS}-${transfer_tag}"

remote_down_selected() {
  local host="$1"
  # Try user's preferred command first; fallback for Compose variants that don't support it.
  ssh "$host" "cd '$COMPOSE_ROOT' && docker compose down $service_args" || {
    echo "[$host] compose down <services> not accepted, fallback to stop <services>"
    ssh "$host" "cd '$COMPOSE_ROOT' && docker compose stop $service_args"
  }
}

echo ">>> Pre-check: SSH reachability"
ssh -o BatchMode=yes "$SRC_ALIAS" "true" >/dev/null
ssh -o BatchMode=yes "$DST_ALIAS" "true" >/dev/null

echo ">>> Step 1/5: Stop selected services on source ($SRC_ALIAS)"
remote_down_selected "$SRC_ALIAS"

echo ">>> Step 2/5: Pull service folders from source -> local stage"
mkdir -p "$local_stage_dir"
for svc in "${SERVICES[@]}"; do
  ssh "$SRC_ALIAS" "test -d '$COMPOSE_ROOT/$svc'" || {
    echo "Source folder missing: $COMPOSE_ROOT/$svc" >&2
    exit 1
  }
  mkdir -p "$local_stage_dir/$svc"
  rsync -a --delete "$SRC_ALIAS:$COMPOSE_ROOT/$svc/" "$local_stage_dir/$svc/"
done

echo ">>> Step 3/5: Stop selected services on destination ($DST_ALIAS)"
remote_down_selected "$DST_ALIAS"

echo ">>> Step 4/5: Backup destination folders and push new data"
for svc in "${SERVICES[@]}"; do
  ssh "$DST_ALIAS" "if [ -e '$COMPOSE_ROOT/$svc' ]; then mv '$COMPOSE_ROOT/$svc' \"\$HOME/${svc}-before-transfer-${transfer_tag}\"; fi"
  rsync -a "$local_stage_dir/$svc/" "$DST_ALIAS:$COMPOSE_ROOT/$svc/"
done

echo ">>> Step 5/5: Start selected services on destination ($DST_ALIAS)"
ssh "$DST_ALIAS" "cd '$COMPOSE_ROOT' && docker compose up -d $service_args"

echo
echo "Service transfer completed."
echo "Local stage dir: $local_stage_dir"
echo "Destination backup tag: *-before-transfer-${transfer_tag}"
