#!/usr/bin/env bash
set -euo pipefail

DEFAULT_PROVIDER="sb"
DEFAULT_MODE="reality"
DEFAULT_OPERATION="add"
DEFAULTS_FILE="/srv/compose/ops_defaults.env"
if [[ -f "$DEFAULTS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$DEFAULTS_FILE"
fi

DEFAULT_DOMAIN="${PROXY_DEFAULT_DOMAIN:-example.com}"
DEFAULT_WS_DOMAIN="${PROXY_DEFAULT_WS_DOMAIN:-$DEFAULT_DOMAIN}"
DEFAULT_REALITY_PORT="${PROXY_DEFAULT_REALITY_PORT:-25102}"
UUID="${PROXY_UUID:-11111111-1111-1111-1111-111111111111}"
WS_PATH="${PROXY_WS_PATH:-/ws}"
REALITY_SHORT_ID="${PROXY_REALITY_SHORT_ID:-00000000}"

PROVIDER=""
MODE=""
OPERATION=""
DOMAIN=""
REALITY_PORT=""

usage() {
  cat <<'EOF'
Usage: proxy_vless.sh [-p sb|xray] [-m reality|ws_tls] [-o add|change] [-d DOMAIN] [-r REALITY_PORT]
  -p  Provider (sb or xray)
  -m  Mode: reality or ws_tls
  -o  Operation: add or change (only used for sb + reality)
  -d  Domain (required for ws_tls, optional for reality)
  -r  Reality listen port (only for reality)
EOF
  exit 1
}

while getopts "p:m:o:d:r:h" opt; do
  case "$opt" in
    p) PROVIDER="$OPTARG" ;;
    m) MODE="$OPTARG" ;;
    o) OPERATION="$OPTARG" ;;
    d) DOMAIN="$OPTARG" ;;
    r) REALITY_PORT="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

ask() {
  local prompt="$1" default="$2" reply
  read -r -p "${prompt} [${default}]: " reply
  echo "${reply:-$default}"
}

if [[ -z "$PROVIDER" ]]; then
  PROVIDER="$(ask "Choose provider (sb/xray)" "$DEFAULT_PROVIDER")"
fi
PROVIDER="${PROVIDER,,}"
if [[ "$PROVIDER" != "sb" && "$PROVIDER" != "xray" ]]; then
  echo "Error: provider must be 'sb' or 'xray'"
  exit 1
fi

if [[ -z "$MODE" ]]; then
  MODE="$(ask "Choose mode (reality/ws_tls)" "$DEFAULT_MODE")"
fi
MODE="${MODE,,}"
if [[ "$MODE" != "reality" && "$MODE" != "ws_tls" ]]; then
  echo "Error: mode must be 'reality' or 'ws_tls'"
  exit 1
fi

if [[ "$MODE" == "reality" && "$PROVIDER" == "sb" ]]; then
  if [[ -z "$OPERATION" ]]; then
    OPERATION="$(ask "Choose operation (add/change)" "$DEFAULT_OPERATION")"
  fi
  OPERATION="${OPERATION,,}"
  if [[ "$OPERATION" != "add" && "$OPERATION" != "change" ]]; then
    echo "Error: operation must be 'add' or 'change'"
    exit 1
  fi
else
  if [[ -n "$OPERATION" ]]; then
    echo "Note: -o is ignored unless provider=sb and mode=reality."
  fi
  OPERATION="add"
fi

ensure_sb() {
  if command -v sb >/dev/null 2>&1; then
    return 0
  fi
  echo "sb not found, installing sing-box..."
  if ! sudo bash -c 'bash <(wget -qO- -o- https://github.com/233boy/sing-box/raw/main/install.sh)'; then
    echo "Warning: sing-box install script exited non-zero; continuing to verify..."
  fi
  if ! command -v sb >/dev/null 2>&1; then
    echo "Error: sb still not found after install attempt"
    exit 1
  fi
}

ensure_xray() {
  if command -v xray >/dev/null 2>&1; then
    return 0
  fi
  echo "xray not found, installing..."
  if ! sudo bash -c 'bash <(wget -qO- -o- https://github.com/233boy/Xray/raw/main/install.sh)'; then
    echo "Warning: xray install script exited non-zero; continuing to verify..."
  fi
  if ! command -v xray >/dev/null 2>&1; then
    echo "Error: xray still not found after install attempt"
    exit 1
  fi
}

patch_233boy_init() {
  local init_sh="$1"
  if [[ ! -f "$init_sh" ]]; then
    echo "Error: $init_sh not found. Is the provider installed?"
    exit 1
  fi
  if ! grep -q "if \\[\\[ false" "$init_sh"; then
    echo "Patching 233boy init.sh to disable caddy management..."
    sudo cp "$init_sh" "${init_sh}.bak"
    sudo sed -i 's/if \\[\\[ -f \\$is_caddy_bin/if [[ false/' "$init_sh"
    grep -q "if \\[\\[ false" "$init_sh" && echo "Patch applied successfully" || { echo "Error: patch failed!"; exit 1; }
  else
    echo "init.sh already patched, skipping"
  fi
}

apply_xray_edge_case_fix() {
  local config_path="/etc/xray/config.json"

  if [[ ! -f "$config_path" ]]; then
    echo "Warning: $config_path not found, skip gstatic/googleapis fix"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not found, skip gstatic/googleapis fix"
    return 0
  fi

  sudo python3 - "$config_path" <<'PY'
import datetime
import json
import shutil
import sys

config_path = sys.argv[1]
with open(config_path, "r", encoding="utf-8") as f:
    config = json.load(f)

rules = config.setdefault("routing", {}).setdefault("rules", [])
new_rule = {
    "type": "field",
    "domain": ["gstatic.com", "googleapis.cn"],
    "marktag": "fix_gstatic_googleapis",
    "outboundTag": "direct",
}

def match_domain_rule(rule):
    return (
        rule.get("type") == "field"
        and set(rule.get("domain", [])) == {"gstatic.com", "googleapis.cn"}
        and rule.get("outboundTag") == "direct"
    )

changed = False

for idx, rule in enumerate(rules):
    if rule.get("marktag") == "fix_gstatic_googleapis":
        if rule != new_rule:
            rules[idx] = new_rule
            changed = True
        break
else:
    for idx, rule in enumerate(rules):
        if match_domain_rule(rule):
            if rule != new_rule:
                rules[idx] = new_rule
                changed = True
            break
    else:
        insert_at = None
        for idx, rule in enumerate(rules):
            if (
                rule.get("type") == "field"
                and "domain" in rule
                and "geosite:openai" in rule.get("domain", [])
            ):
                insert_at = idx + 1
                break
        if insert_at is None:
            rules.append(new_rule)
        else:
            rules.insert(insert_at, new_rule)
        changed = True

if changed:
    backup_path = f"{config_path}.bak.{datetime.datetime.now().strftime('%F_%H%M%S')}"
    shutil.copy2(config_path, backup_path)
    print(f"Backup created: {backup_path}")
    with open(config_path, "w", encoding="utf-8") as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("Rule fix_gstatic_googleapis added/updated.")
else:
    print("No changes needed: rule already exists.")
PY

  if sudo xray run -test -c "$config_path"; then
    sudo xray restart
  else
    echo "Warning: xray config test failed, skip restart"
  fi
}

reload_caddy() {
  echo "Reloading your Docker Compose Caddy..."
  if sudo bash -lc "cd /srv/compose && docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile"; then
    :
  elif sudo bash -lc "cd /srv/compose && docker compose exec xcaddy caddy reload --config /etc/caddy/Caddyfile"; then
    :
  else
    echo "Error: failed to reload Caddy via docker compose (service caddy/xcaddy not running?)"
    exit 1
  fi
}

copy_caddy_conf() {
  local domain="$1"
  local src="/etc/caddy/233boy/${domain}.conf"
  local dest="/srv/compose/caddy/sites/${domain}.conf"

  sudo mkdir -p /srv/compose/caddy/sites

  if [[ ! -f "$src" ]]; then
    echo "Error: $src not found — did provider add succeed?"
    exit 1
  fi

  echo "Copying $src -> $dest"
  sudo cp "$src" "$dest"

  echo "Removing import line from $dest"
  sudo sed -i '/import \\/etc\\/caddy\\/233boy\\//d' "$dest"
  echo "Cleaned conf:"
  cat "$dest"
}

set_sb_reality_short_id() {
  local target_port="${1:-${REALITY_PORT:-}}"
  local config=""

  if [[ -z "$target_port" ]]; then
    target_port="$(
      sudo bash -lc '
        shopt -s nullglob
        files=(/etc/sing-box/conf/VLESS-REALITY-*.json)
        if (( ${#files[@]} == 0 )); then
          exit 0
        fi
        latest="$(ls -1t /etc/sing-box/conf/VLESS-REALITY-*.json 2>/dev/null | head -n1)"
        base="$(basename "$latest")"
        echo "${base#VLESS-REALITY-}" | sed "s/\.json$//"
      ' 2>/dev/null || true
    )"
  fi

  if [[ -z "$target_port" ]]; then
    echo "Warning: cannot detect REALITY port for short_id patch. Skipping."
    return 0
  fi

  config="/etc/sing-box/conf/VLESS-REALITY-${target_port}.json"
  if [[ ! -f "$config" ]]; then
    echo "Warning: $config not found. Skipping short_id update."
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    echo "Warning: python3 not found. Skipping short_id update."
    return 0
  fi

  sudo python3 - <<PY
import json
from pathlib import Path

path = Path("${config}")
data = json.loads(path.read_text())

inbounds = data.setdefault("inbounds", [])
if not inbounds:
    inbounds.append({})
tls = inbounds[0].setdefault("tls", {})
reality = tls.setdefault("reality", {})
reality["short_id"] = ["${REALITY_SHORT_ID}"]

path.write_text(json.dumps(data, ensure_ascii=False, indent=2))
PY
  sudo sb restart >/dev/null 2>&1
  echo "Sing-box restarted to apply REALITY short_id on port ${target_port}"
}

if [[ "$MODE" == "ws_tls" ]]; then
  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$(ask "Enter domain" "$DEFAULT_WS_DOMAIN")"
  fi
  if [[ -z "$DOMAIN" ]]; then
    echo "Error: domain cannot be empty"
    exit 1
  fi

  if [[ "$PROVIDER" == "sb" ]]; then
    ensure_sb
    patch_233boy_init "/etc/sing-box/sh/src/init.sh"
    if ! sudo sb del REALITY; then
      echo "No existing REALITY node found (or already removed), continuing..."
    fi
    sudo sb add vws "$DOMAIN" "$UUID" "$WS_PATH"
  else
    ensure_xray
    patch_233boy_init "/etc/xray/sh/src/init.sh"
    sudo xray add vws "$DOMAIN" "$UUID" "$WS_PATH"
    apply_xray_edge_case_fix
  fi

  copy_caddy_conf "$DOMAIN"
  reload_caddy
  echo "Done. VLESS+WS_TLS config written to /srv/compose/caddy/sites/${DOMAIN}.conf"
  exit 0
fi

SB_INTERACTIVE_CHANGE="false"
if [[ "$PROVIDER" == "sb" && "$OPERATION" == "change" && -z "$DOMAIN" && -z "$REALITY_PORT" ]]; then
  SB_INTERACTIVE_CHANGE="true"
fi

if [[ "$SB_INTERACTIVE_CHANGE" != "true" ]]; then
  if [[ -z "$DOMAIN" ]]; then
    DOMAIN="$(ask "Enter reality target domain" "$DEFAULT_DOMAIN")"
  fi

  if [[ -z "$REALITY_PORT" ]]; then
    if [[ "$PROVIDER" == "sb" && "$OPERATION" == "change" ]]; then
      REALITY_PORT="$(
        sudo bash -lc '
          shopt -s nullglob
          files=(/etc/sing-box/conf/VLESS-REALITY-*.json)
          if (( ${#files[@]} == 0 )); then
            exit 0
          fi
          latest="$(ls -1t /etc/sing-box/conf/VLESS-REALITY-*.json 2>/dev/null | head -n1)"
          base="$(basename "$latest")"
          echo "${base#VLESS-REALITY-}" | sed "s/\.json$//"
        ' 2>/dev/null || true
      )"
    fi
    REALITY_PORT="${REALITY_PORT:-$(ask "Enter REALITY listen port" "$DEFAULT_REALITY_PORT")}"
  fi

  if ! [[ "$REALITY_PORT" =~ ^[0-9]+$ ]] || (( REALITY_PORT < 1 || REALITY_PORT > 65535 )); then
    echo "Error: invalid port '${REALITY_PORT}'. Use an integer between 1 and 65535."
    exit 1
  fi
fi

if [[ "$PROVIDER" == "sb" ]]; then
  ensure_sb
  if [[ "$SB_INTERACTIVE_CHANGE" == "true" ]]; then
    echo "Running interactive change via: sudo sb change"
    sudo sb change
    set_sb_reality_short_id
    echo "Done. Sing-box REALITY config changed interactively."
  else
    if ! sudo sb del REALITY; then
      echo "No existing REALITY node found (or already removed), continuing..."
    fi
    sudo sb add reality "${REALITY_PORT}" auto "${DOMAIN}"
    set_sb_reality_short_id "${REALITY_PORT}"
    if [[ "$OPERATION" == "change" ]]; then
      echo "Done. Sing-box REALITY config changed (port/domain) and short_id reapplied."
    else
      echo "Done. Sing-box REALITY config added and short_id applied."
    fi
  fi
else
  ensure_xray
  if [[ "$OPERATION" == "change" ]]; then
    echo "Applying Xray REALITY change using del/add flow..."
  fi
  if ! sudo xray del REALITY; then
    echo "No existing REALITY node found (or already removed), continuing..."
  fi
  sudo xray add reality "${REALITY_PORT}" auto "${DOMAIN}"
  apply_xray_edge_case_fix
  if [[ "$OPERATION" == "change" ]]; then
    echo "Done. Xray REALITY config changed."
  else
    echo "Done. Xray REALITY config added."
  fi
fi
