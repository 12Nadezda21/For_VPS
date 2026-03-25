#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BASH_VERSION:-}" ]]; then
  echo "Please run with bash: bash AllinOne.sh ..." >&2
  exit 1
fi

# ─────────────────────────────────────────────
#  IniVPS — One-Click Deploy
#  Covers: Preflight → Step 1 (Ansible) → SSH config → Step 2 (Ansible sync) → Step 3 (Docker up)
# ─────────────────────────────────────────────

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RED="\033[0;31m"
RESET="\033[0m"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ANSIBLE_DIR="$SCRIPT_DIR/ansible"

# ── Ansible-configured defaults (must match ansible/vars) ──
ANSIBLE_NEW_USER="vpsadmin"
ANSIBLE_NEW_PORT="30022"
DOCKER_DEST="/srv/compose"

# ─────────────────────────────────────────────
#  Helpers
# ─────────────────────────────────────────────
step() { echo -e "\n${CYAN}${BOLD}▶ $*${RESET}"; }
ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()  { echo -e "${RED}✖ $*${RESET}" >&2; exit 1; }

ask_yesno() {
  local prompt="$1" default="${2:-y}" reply lowered suffix
  [[ "$default" == "y" ]] && suffix="[Y/n]" || suffix="[y/N]"
  read -r -p "  $prompt $suffix: " reply
  reply="${reply:-$default}"
  lowered="$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')"
  [[ "$lowered" == "y" || "$lowered" == "yes" ]]
}

REMOTE_DEFAULTS_LOADED="no"
REMOTE_CADDY_DEFAULT_ENGINE="caddy"
REMOTE_SERVICE_AUTO_START=""
REMOTE_SERVICE_DEFAULT_KOMARI="n"
REMOTE_SERVICE_DEFAULT_OPENLIST="n"
REMOTE_SERVICE_DEFAULT_EASYIMAGE="n"
REMOTE_SERVICE_DEFAULT_VAULTWARDEN="n"
REMOTE_SERVICE_DEFAULT_CLIPROXYAPI="n"
REMOTE_SERVICE_DEFAULT_SUB_STORE="n"
STEP1_PROMPT_RESET_WHEN_ALIAS_EXISTS="yes"
ANSIBLE_VAULT_ARGS=()

read_local_scalar_var() {
  local key="$1" vars_file="${ANSIBLE_DIR}/vars.yml"
  [[ -f "$vars_file" ]] || return 1

  awk -F':' -v k="$key" '
    $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      val=$2
      sub(/^[[:space:]]*/, "", val)
      sub(/[[:space:]]*$/, "", val)
      gsub(/^["'\''"]|["'\''"]$/, "", val)
      print val
      exit
    }
  ' "$vars_file"
}

build_vault_args() {
  ANSIBLE_VAULT_ARGS=()
  local vault_file="${ANSIBLE_DIR}/vault.yml"
  if [[ -f "$vault_file" ]] && grep -q '^\\$ANSIBLE_VAULT' "$vault_file"; then
    if [[ -f "${ANSIBLE_DIR}/.vault_pass" ]]; then
      ANSIBLE_VAULT_ARGS+=(--vault-password-file "${ANSIBLE_DIR}/.vault_pass")
    else
      ANSIBLE_VAULT_ARGS+=(--ask-vault-pass)
    fi
  fi
}

is_tcp_reachable() {
  local host="$1" port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -z -w 3 "$host" "$port" >/dev/null 2>&1
  else
    timeout 3 bash -c ":</dev/tcp/${host}/${port}" >/dev/null 2>&1
  fi
}

load_remote_ops_defaults() {
  [[ "$REMOTE_DEFAULTS_LOADED" == "yes" ]] && return 0

  local output=""
  output="$(ssh "${VPS_ALIAS}" "if [ -f '${DOCKER_DEST}/ops_defaults.env' ]; then \
    set -a; . '${DOCKER_DEST}/ops_defaults.env'; set +a; \
    printf 'CADDY_DEFAULT_ENGINE=%s\n' \"\${CADDY_DEFAULT_ENGINE:-caddy}\"; \
    printf 'SERVICE_AUTO_START=%s\n' \"\${SERVICE_AUTO_START:-}\"; \
    printf 'SERVICE_DEFAULT_KOMARI=%s\n' \"\${SERVICE_DEFAULT_KOMARI:-n}\"; \
    printf 'SERVICE_DEFAULT_OPENLIST=%s\n' \"\${SERVICE_DEFAULT_OPENLIST:-n}\"; \
    printf 'SERVICE_DEFAULT_EASYIMAGE=%s\n' \"\${SERVICE_DEFAULT_EASYIMAGE:-n}\"; \
    printf 'SERVICE_DEFAULT_VAULTWARDEN=%s\n' \"\${SERVICE_DEFAULT_VAULTWARDEN:-n}\"; \
    printf 'SERVICE_DEFAULT_CLIPROXYAPI=%s\n' \"\${SERVICE_DEFAULT_CLIPROXYAPI:-n}\"; \
    printf 'SERVICE_DEFAULT_SUB_STORE=%s\n' \"\${SERVICE_DEFAULT_SUB_STORE:-n}\"; \
  fi" 2>/dev/null || true)"

  [[ -z "$output" ]] && return 1

  while IFS='=' read -r key val; do
    case "$key" in
      CADDY_DEFAULT_ENGINE)       REMOTE_CADDY_DEFAULT_ENGINE="${val,,}" ;;
      SERVICE_AUTO_START)         REMOTE_SERVICE_AUTO_START="$val" ;;
      SERVICE_DEFAULT_KOMARI)     REMOTE_SERVICE_DEFAULT_KOMARI="${val,,}" ;;
      SERVICE_DEFAULT_OPENLIST)   REMOTE_SERVICE_DEFAULT_OPENLIST="${val,,}" ;;
      SERVICE_DEFAULT_EASYIMAGE)  REMOTE_SERVICE_DEFAULT_EASYIMAGE="${val,,}" ;;
      SERVICE_DEFAULT_VAULTWARDEN) REMOTE_SERVICE_DEFAULT_VAULTWARDEN="${val,,}" ;;
      SERVICE_DEFAULT_CLIPROXYAPI) REMOTE_SERVICE_DEFAULT_CLIPROXYAPI="${val,,}" ;;
      SERVICE_DEFAULT_SUB_STORE)  REMOTE_SERVICE_DEFAULT_SUB_STORE="${val,,}" ;;
    esac
  done <<< "$output"

  REMOTE_DEFAULTS_LOADED="yes"
  return 0
}

refresh_remote_ops_defaults() {
  REMOTE_DEFAULTS_LOADED="no"
  load_remote_ops_defaults || true
}

remote_sudo() {
  local cmd="$1"
  if [[ -n "$SUDO_PASSWORD" ]]; then
    ssh "${VPS_ALIAS}" "sudo -S bash -lc $(printf '%q' "$cmd")" <<<"$SUDO_PASSWORD"
  else
    ssh -t "${VPS_ALIAS}" "sudo bash -lc $(printf '%q' "$cmd")"
  fi
}

has_exact_ssh_alias() {
  local alias_name="$1" ssh_config="${HOME}/.ssh/config"
  [[ -f "$ssh_config" ]] || return 1

  awk -v target="$alias_name" '
    tolower($1) == "host" {
      for (i = 2; i <= NF; i++) {
        if ($i == target) {
          found = 1
        }
      }
    }
    END { exit(found ? 0 : 1) }
  ' "$ssh_config"
}

can_login_with_alias() {
  local alias_name="$1"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "${alias_name}" "exit 0" >/dev/null 2>&1
}

apply_caddy_template_on_remote() {
  ssh "${VPS_ALIAS}" "test -f ${DOCKER_DEST}/${CADDY_TEMPLATE}" \
    || die "Missing ${DOCKER_DEST}/${CADDY_TEMPLATE} on VPS. Run Step 2 to sync Docker files."

  ssh "${VPS_ALIAS}" "cp ${DOCKER_DEST}/${CADDY_TEMPLATE} ${DOCKER_DEST}/Caddyfile"
  ok "Applied ${CADDY_TEMPLATE} as ${DOCKER_DEST}/Caddyfile"
}

seed_caddy_conf_if_available() {
  local service="$1"
  local src="${SCRIPT_DIR}/caddy-sites/${service}.conf.example"
  local dest="${DOCKER_DEST}/caddy/sites/${service}.conf.example"
  local upstream=""

  if ssh "${VPS_ALIAS}" "test -f ${dest}"; then
    warn "Caddy example already exists: ${dest}"
    warn "Edit the listening domain inside ${dest}, then copy it to ${dest%.example} and reload Caddy"
    return 0
  fi

  if [[ -f "$src" ]]; then
    if command -v rg >/dev/null 2>&1; then
      rg -q "\{\{" "$src" && {
        warn "Caddy example is a template; run Step 2 (Ansible sync) to render it with vars.yml"
        return 0
      }
    elif grep -q "{{" "$src"; then
      warn "Caddy example is a template; run Step 2 (Ansible sync) to render it with vars.yml"
      return 0
    fi
    ssh "${VPS_ALIAS}" "cat > ${dest}" < "${src}"
    ok "Added Caddy example: ${dest}"
    warn "Edit the listening domain inside ${dest}, then copy it to ${dest%.example} and reload Caddy"
    return 0
  fi

  case "$service" in
    komari)      upstream="127.0.0.1:25774" ;;
    openlist)    upstream="127.0.0.1:5244" ;;
    easyimage)   upstream="127.0.0.1:8080" ;;
    vaultwarden) upstream="127.0.0.1:8000" ;;
    cliproxyapi) upstream="127.0.0.1:8317" ;;
    sub-store)   upstream="127.0.0.1:9876" ;;
    *)           upstream="127.0.0.1:PORT" ;;
  esac

  {
    printf '%s\n' "# Edit the domain, then copy to ${dest%.example}"
    printf '%s\n' "# After DNS is ready, run: cd /srv/compose && (docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile || docker compose exec xcaddy caddy reload --config /etc/caddy/Caddyfile)"
    printf '%s\n' ""
    printf '%s\n' "${service}.server.site:443 {"
    printf '%s\n' "    reverse_proxy ${upstream}"
    printf '%s\n' "}"
  } | ssh "${VPS_ALIAS}" "cat > ${dest}"

  ok "Generated Caddy example: ${dest}"
  warn "Edit the listening domain inside ${dest}, then copy it to ${dest%.example} and reload Caddy"
}

configure_auto_backup_cron() {
  local local_script="${SCRIPT_DIR}/ops_scripts/compose_backup.sh"
  [[ -f "$local_script" ]] || die "Missing backup script at ${local_script}"

  ssh "${VPS_ALIAS}" "mkdir -p ${DOCKER_DEST}"
  ssh "${VPS_ALIAS}" "cat > ${DOCKER_DEST}/compose_backup.sh" < "$local_script"
  ssh "${VPS_ALIAS}" "chmod +x ${DOCKER_DEST}/compose_backup.sh"
  ok "Backup script uploaded: ${DOCKER_DEST}/compose_backup.sh"

ssh "${VPS_ALIAS}" "COMPOSE_ROOT='${DOCKER_DEST}' VPS_NAME='${VPS_ALIAS}' bash -s" <<'EOF'
set -euo pipefail

command -v rclone >/dev/null 2>&1 || {
  echo "rclone not found on VPS. Run Step 1 first to install it."
  exit 1
}
test -x "${COMPOSE_ROOT}/compose_backup.sh" || {
  echo "Missing executable backup script: ${COMPOSE_ROOT}/compose_backup.sh"
  exit 1
}

if [[ -f "${COMPOSE_ROOT}/ops_defaults.env" ]]; then
  # shellcheck disable=SC1090
  source "${COMPOSE_ROOT}/ops_defaults.env"
fi

rclone config show "${RCLONE_REMOTE_NAME:-remote}" >/dev/null 2>&1 || {
  echo "rclone remote '${RCLONE_REMOTE_NAME:-remote}' not configured. Run Step 1 first to configure backup remote."
  exit 1
}

tmp_user_cron="$(mktemp)"
crontab -l 2>/dev/null | grep -v 'Docker Compose Backup to WebDAV' > "$tmp_user_cron" || true
CRON_SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 */12 * * *}"
echo "${CRON_SCHEDULE} COMPOSE_ROOT=${COMPOSE_ROOT} ${COMPOSE_ROOT}/compose_backup.sh ${VPS_NAME} # Docker Compose Backup to WebDAV" >> "$tmp_user_cron"
crontab "$tmp_user_cron"
rm -f "$tmp_user_cron"

# Best-effort cleanup for legacy root cron entry from older versions.
if sudo -n true >/dev/null 2>&1; then
  tmp_root_cron="$(mktemp)"
  sudo crontab -l 2>/dev/null | grep -v 'Docker Compose Backup to WebDAV' > "$tmp_root_cron" || true
  sudo crontab "$tmp_root_cron"
  rm -f "$tmp_root_cron"
fi
EOF

  ok "Auto backup cron enabled (every 12 hours)"
}

disable_auto_backup_cron() {
  ssh "${VPS_ALIAS}" "bash -s" <<'EOF'
set -euo pipefail
tmp_user_cron="$(mktemp)"
crontab -l 2>/dev/null | grep -v 'Docker Compose Backup to WebDAV' > "$tmp_user_cron" || true
crontab "$tmp_user_cron"
rm -f "$tmp_user_cron"

# Best-effort cleanup for legacy root cron entry from older versions.
if sudo -n true >/dev/null 2>&1; then
  tmp_root_cron="$(mktemp)"
  sudo crontab -l 2>/dev/null | grep -v 'Docker Compose Backup to WebDAV' > "$tmp_root_cron" || true
  sudo crontab "$tmp_root_cron"
  rm -f "$tmp_root_cron"
fi
EOF

  ok "Auto backup cron disabled (if previously configured)"
}

# ─────────────────────────────────────────────
#  Parse args
# ─────────────────────────────────────────────
usage() {
  echo -e "Usage: $0 -a ALIAS -i IP [-p PORT] [-s PASSWORD] [-w SUDO_PASSWORD] [-k] [-d] [-u]"
  echo -e "  -a  VPS alias (e.g. myserver)"
  echo -e "  -i  VPS IP    (e.g. 1.2.3.4)"
  echo -e "  -p  Root SSH port         (required only when Step 1 runs)"
  echo -e "  -s  Root SSH password     (required only when Step 1 runs)"
  echo -e "  -w  Sudo password for VPS user (optional, for non-interactive sudo)"
  echo -e "  -k  Skip Step 1 (Ansible) and Step 1.5 (SSH config)"
  echo -e "  -d  Skip Step 2 (Docker sync)"
  echo -e "  -u  Skip Step 3 (Docker up)"
  exit 1
}

VPS_ALIAS="" VPS_IP="" SSH_PORT="" ROOT_PASSWORD="" SUDO_PASSWORD="" SKIP_STEP1="" SKIP_STEP2="" SKIP_STEP3=""
ENABLE_BACKUP_CRON="no"

while getopts "a:i:p:s:w:kdu" opt; do
  case $opt in
    a) VPS_ALIAS="$OPTARG" ;;
    i) VPS_IP="$OPTARG" ;;
    p) SSH_PORT="$OPTARG" ;;
    s) ROOT_PASSWORD="$OPTARG" ;;
    w) SUDO_PASSWORD="$OPTARG" ;;
    k) SKIP_STEP1="yes" ;;
    d) SKIP_STEP2="yes" ;;
    u) SKIP_STEP3="yes" ;;
    *) usage ;;
  esac
done

[[ -z "$VPS_ALIAS" || -z "$VPS_IP" ]] && usage

ALIAS_IN_CONFIG="no"
ALIAS_REACHABLE="no"
if has_exact_ssh_alias "$VPS_ALIAS"; then
  ALIAS_IN_CONFIG="yes"
  if can_login_with_alias "$VPS_ALIAS"; then
    ALIAS_REACHABLE="yes"
  fi
fi

echo -e "
${BOLD}╔══════════════════════════════════╗"
echo -e "║    IniVPS  ·  One-Click Deploy      ║"
echo -e "╚══════════════════════════════════╝${RESET}
"
echo -e "  Alias   : ${CYAN}${VPS_ALIAS}${RESET}"
echo -e "  IP      : ${CYAN}${VPS_IP}${RESET}"
[[ -n "$SSH_PORT" ]] && echo -e "  Port    : ${CYAN}${SSH_PORT}${RESET}"
if [[ "$ALIAS_REACHABLE" == "yes" ]]; then
  echo -e "  Mode    : ${CYAN}existing host (alias login available)${RESET}"
elif [[ "$ALIAS_IN_CONFIG" == "yes" ]]; then
  echo -e "  Mode    : ${YELLOW}alias found (batch login check failed)${RESET}"
else
  echo -e "  Mode    : ${CYAN}first bootstrap (no alias login yet)${RESET}"
fi
echo

# ─────────────────────────────────────────────
#  Prompt to skip Step 1 (if not already decided via -k)
# ─────────────────────────────────────────────
if [[ -z "$SKIP_STEP1" ]]; then
  step1_default="y"
  if [[ "$ALIAS_IN_CONFIG" == "yes" || "$ALIAS_REACHABLE" == "yes" ]]; then
    step1_default="n"
  fi

  if ! ask_yesno "Run Step 1 (Ansible VPS initialisation)?" "$step1_default"; then
    SKIP_STEP1="yes"
    warn "Step 1 (Ansible) and Step 1.5 (SSH config) will be skipped."
  fi
fi

# Step 1 runs only with root credentials.
if [[ -z "$SKIP_STEP1" && ( -z "$SSH_PORT" || -z "$ROOT_PASSWORD" ) ]]; then
  die "Step 1 requires root SSH port/password. Provide -p and -s, or skip Step 1."
fi

# If Step 1 is skipped, alias login must already work for Step 2/3.
if [[ -n "$SKIP_STEP1" && "$ALIAS_REACHABLE" != "yes" ]]; then
  die "Step 1 is skipped, but SSH alias '${VPS_ALIAS}' is not reachable. Run Step 1 first or fix ~/.ssh/config connectivity."
fi

local_step1_reset_prompt="$(read_local_scalar_var "step1_prompt_reset_ssh_when_alias_exists" || true)"
if [[ -n "$local_step1_reset_prompt" ]]; then
  STEP1_PROMPT_RESET_WHEN_ALIAS_EXISTS="${local_step1_reset_prompt,,}"
fi

if [[ -z "$SKIP_STEP2" ]]; then
  if ! ask_yesno "Run Step 2 (Docker sync)?" "y"; then
    SKIP_STEP2="yes"
    warn "Step 2 (Docker sync) will be skipped."
  fi
fi

if [[ -z "$SKIP_STEP3" ]]; then
  if ! ask_yesno "Run Step 3 (Docker up)?" "y"; then
    SKIP_STEP3="yes"
    warn "Step 3 (Docker up) will be skipped."
  fi
fi

if ask_yesno "Enable 12-hour automated backup cron (rclone WebDAV)?" "n"; then
  ENABLE_BACKUP_CRON="yes"
fi

CADDY_SERVICE="caddy"
CADDY_TEMPLATE="Caddyfile.template"
if [[ "$SKIP_STEP2" != "yes" || "$SKIP_STEP3" != "yes" ]]; then
  default_caddy_prompt="n"
  if [[ "$ALIAS_REACHABLE" == "yes" ]]; then
    load_remote_ops_defaults || true
    if [[ "${REMOTE_CADDY_DEFAULT_ENGINE}" == "xcaddy" ]]; then
      default_caddy_prompt="y"
    fi
  fi

  if ask_yesno "Use XCaddy (caddy-l4) instead of standard Caddy?" "${default_caddy_prompt}"; then
    CADDY_SERVICE="xcaddy"
    CADDY_TEMPLATE="XCaddyfile.template"
  fi
fi

# ─────────────────────────────────────────────
#  Preflight Checks
# ─────────────────────────────────────────────
run_preflight() {
  step "Running Pre-flight Checks..."

  for tool in ansible-playbook ssh; do
    command -v "$tool" &>/dev/null || die "$tool is not installed. Please install it first."
  done
  ok "Base tools found (ansible, ssh)"

  local ansible_python
  ansible_python="$(ansible --version 2>/dev/null | grep 'python version' | grep -o '([^)]*)' | tail -1 | tr -d '()')"
  [[ -z "$ansible_python" || ! -f "$ansible_python" ]] && die "Cannot detect Ansible's Python. Run 'ansible --version'."

  if "$ansible_python" -m pip show passlib >/dev/null 2>&1; then
    ok "Ansible Python passlib module found"
  else
    die "passlib missing. Run: $ansible_python -m pip install passlib"
  fi

  [[ -d "$ANSIBLE_DIR" ]] || die "ansible/ directory not found at $ANSIBLE_DIR"
  for f in ini.yml vars.yml vault.yml ansible.cfg; do
    [[ -f "$ANSIBLE_DIR/$f" ]] || die "$f missing in $ANSIBLE_DIR"
  done
  if grep -q '^\\$ANSIBLE_VAULT' "$ANSIBLE_DIR/vault.yml"; then
    if [[ -f "$ANSIBLE_DIR/.vault_pass" ]]; then
      ok "Ansible vault password file found"
    else
      warn "vault.yml is encrypted but ansible/.vault_pass is missing — you will be prompted for a vault password"
    fi
  fi
  ok "All required Ansible configuration files present"

  grep -q "interpreter_python" "$ANSIBLE_DIR/ansible.cfg" || die "ansible.cfg: interpreter_python not set"

  local vars_file="$ANSIBLE_DIR/vars.yml"
  for key in ssh_port new_user ssh_pubkeys caddy_acme_email; do
    grep -q "^$key:" "$vars_file" || die "vars.yml: $key missing"
  done

  local pubkey
  pubkey="$(grep -A1 '^ssh_pubkeys:' "$vars_file" | tail -1 | tr -d " -'\"")"
  [[ -n "$pubkey" ]] || die "ssh_pubkeys appears empty in vars.yml"

  local email
  email="$(grep '^caddy_acme_email:' "$vars_file" | awk '{print $2}' | tr -d "'\"")"
  if [[ -z "$email" || "$email" == "you@example.com" || "$email" == *@example.com || "$email" == *@example.net || "$email" == *@example.org ]]; then
    warn "caddy_acme_email is not set to a real address — Let's Encrypt renewal warnings won't be delivered"
  fi

  ok "Pre-flight checks passed."
}

run_preflight

# ─────────────────────────────────────────────
#  Step 1 — Ansible: initialise VPS
# ─────────────────────────────────────────────
if [[ -n "$SKIP_STEP1" ]]; then
  warn "Skipping Step 1 (Ansible) and Step 1.5 (SSH config) as requested."
else
  step "Step 1 · Running Ansible to initialise VPS..."

  if [[ "${STEP1_PROMPT_RESET_WHEN_ALIAS_EXISTS}" == "yes" && "$ALIAS_IN_CONFIG" == "yes" ]]; then
    warn "Step 1 bootstrap usually needs root/password login on port ${SSH_PORT}."
    if ask_yesno "Run reset-ssh.sh now before Step 1?" "y"; then
      reset_args=( -a "${VPS_ALIAS}" -o "${SSH_PORT}" )
      if [[ -n "$SUDO_PASSWORD" ]]; then
        reset_args+=( -w "$SUDO_PASSWORD" )
      fi
      bash "${SCRIPT_DIR}/reset-ssh.sh" "${reset_args[@]}" || die "reset-ssh.sh failed. Cannot continue Step 1."
    else
      warn "Continuing Step 1 without reset-ssh.sh (may fail if root/password login is closed)."
    fi
  fi

  if [[ -n "$SKIP_STEP1" ]]; then
    :
  else
  cd "$ANSIBLE_DIR"

  step "Refreshing host keys for ${VPS_IP}..."
  ssh-keygen -R "[${VPS_IP}]:${SSH_PORT}"         2>/dev/null || true
  ssh-keygen -R "${VPS_IP}"                        2>/dev/null || true
  ssh-keyscan -p "${SSH_PORT}"         "${VPS_IP}" >> "$HOME/.ssh/known_hosts" 2>/dev/null \
    && ok "Host keys accepted" \
    || warn "ssh-keyscan failed — continuing anyway"

  # Bootstrap/root credentials are only needed for Step 1.
  build_vault_args
  if ansible-playbook -i "${VPS_IP}," ini.yml -vv \
    -e "bootstrap_root_port=${SSH_PORT} bootstrap_root_password=${ROOT_PASSWORD}" \
    --skip-tags sync_docker \
    "${ANSIBLE_VAULT_ARGS[@]}"; then
    ok "Ansible playbook completed"
    cd "$SCRIPT_DIR"

    # ─────────────────────────────────────────────
    #  Step 1.5 — Add SSH config entry
    # ─────────────────────────────────────────────
    step "Step 1.5 · Adding SSH config entry for ${VPS_ALIAS}..."

    SSH_CONFIG="$HOME/.ssh/config"
    mkdir -p "$HOME/.ssh"
    touch "$SSH_CONFIG"
    chmod 600 "$SSH_CONFIG"

    if grep -q "^Host ${VPS_ALIAS}$" "$SSH_CONFIG" 2>/dev/null; then
      warn "Existing entry for '${VPS_ALIAS}' found — replacing it..."
      awk -v target="${VPS_ALIAS}" '
        $1 == "Host" {
          if ($2 == target) { skip = 1 } else { skip = 0; print $0 }
          next
        }
        !skip { print $0 }
      ' "$SSH_CONFIG" > "${SSH_CONFIG}.tmp" && mv "${SSH_CONFIG}.tmp" "$SSH_CONFIG"
    fi

    cat >> "$SSH_CONFIG" <<EOF

Host ${VPS_ALIAS}
  Hostname ${VPS_IP}
  User ${ANSIBLE_NEW_USER}
  Port ${ANSIBLE_NEW_PORT}
  ServerAliveInterval 600
EOF

    ok "SSH config written."
    echo -e "  ${YELLOW}Host ${VPS_ALIAS}"
    echo    "    Hostname ${VPS_IP}"
    echo    "    User     ${ANSIBLE_NEW_USER}"
    echo    "    Port     ${ANSIBLE_NEW_PORT}"
    echo -e "    ServerAliveInterval 600${RESET}"
  else
    cd "$SCRIPT_DIR"
    if has_exact_ssh_alias "$VPS_ALIAS" && can_login_with_alias "$VPS_ALIAS"; then
      warn "Step 1 failed, but SSH alias '${VPS_ALIAS}' is reachable."
      warn "Treating VPS as already initialized and continuing with Step 2/3."
      SKIP_STEP1="yes"
    else
      die "Step 1 failed and alias login is not reachable. Check root SSH port/password or run reset-ssh.sh."
    fi
  fi
  fi
fi
if [[ -n "$SKIP_STEP2" ]]; then
  warn "Skipping Step 2 (Docker sync) as requested."
else
  # ─────────────────────────────────────────────
  #  Step 2 — Sync Docker source to VPS (Ansible)
  # ─────────────────────────────────────────────
  step "Step 2 · Syncing Docker source files via Ansible..."
  (
    cd "$ANSIBLE_DIR"
    build_vault_args
    ansible-playbook -i "${VPS_IP}," ini.yml -vv \
      -u "${ANSIBLE_NEW_USER}" \
      -e "ansible_port=${ANSIBLE_NEW_PORT} selected_caddy_template=${CADDY_TEMPLATE}" \
      --tags sync_docker \
      "${ANSIBLE_VAULT_ARGS[@]}"
  )
  ok "Docker source synced to ${VPS_ALIAS}:${DOCKER_DEST}"
  refresh_remote_ops_defaults
fi

if [[ -n "$SKIP_STEP3" ]]; then
  warn "Skipping Step 3 (Docker up) as requested."
else
  # ─────────────────────────────────────────────
  #  Step 3 — Start services via Docker Compose
  # ─────────────────────────────────────────────
  step "Step 3 · Select services to start..."
  remote_sudo "mkdir -p ${DOCKER_DEST}/caddy/sites && chown ${ANSIBLE_NEW_USER}:${ANSIBLE_NEW_USER} ${DOCKER_DEST}/caddy/sites"
  ok "Caddy sites directory ensured at ${DOCKER_DEST}/caddy/sites"

  services=("${CADDY_SERVICE}")
  caddy_candidates=()
  openlist_selected="no"
  load_remote_ops_defaults || true

  add_unique_value() {
    local value="$1"
    shift
    local item
    for item in "$@"; do
      [[ "$item" == "$value" ]] && return 1
    done
    return 0
  }

  add_service_and_caddy() {
    local svc="$1"
    if add_unique_value "$svc" "${services[@]}"; then
      services+=("$svc")
    fi
    if add_unique_value "$svc" "${caddy_candidates[@]}"; then
      caddy_candidates+=("$svc")
    fi
  }

  auto_services_raw="${REMOTE_SERVICE_AUTO_START}"
  auto_services_raw="$(printf '%s' "$auto_services_raw" | tr ',' ' ' | xargs)"

  if [[ -n "$auto_services_raw" ]]; then
    for svc in $auto_services_raw; do
      case "$svc" in
        komari)
          add_service_and_caddy "komari"
          ;;
        openlist)
          add_service_and_caddy "openlist"
          openlist_selected="yes"
          ;;
        easyimage)
          add_service_and_caddy "easyimage"
          ;;
        vaultwarden)
          add_service_and_caddy "vaultwarden"
          ;;
        cliproxyapi)
          add_service_and_caddy "cliproxyapi"
          ;;
        sub-store|sub_store|substore)
          add_service_and_caddy "sub-store"
          ;;
        *)
          warn "Unknown service in service_auto_start: ${svc}"
          ;;
      esac
    done
  else
    service_default() {
      local key="$1"
      case "$key" in
        komari)      echo "${REMOTE_SERVICE_DEFAULT_KOMARI:-n}" ;;
        openlist)    echo "${REMOTE_SERVICE_DEFAULT_OPENLIST:-n}" ;;
        easyimage)   echo "${REMOTE_SERVICE_DEFAULT_EASYIMAGE:-n}" ;;
        vaultwarden) echo "${REMOTE_SERVICE_DEFAULT_VAULTWARDEN:-n}" ;;
        cliproxyapi) echo "${REMOTE_SERVICE_DEFAULT_CLIPROXYAPI:-n}" ;;
        sub-store)   echo "${REMOTE_SERVICE_DEFAULT_SUB_STORE:-n}" ;;
        *)           echo "n" ;;
      esac
    }

    if ask_yesno "Start Komari?" "$(service_default komari)"; then
      add_service_and_caddy "komari"
    fi

    if ask_yesno "Start OpenList?" "$(service_default openlist)"; then
      add_service_and_caddy "openlist"
      openlist_selected="yes"
    fi

    if ask_yesno "Start EasyImage?" "$(service_default easyimage)"; then
      add_service_and_caddy "easyimage"
    fi

    if ask_yesno "Start Vaultwarden?" "$(service_default vaultwarden)"; then
      add_service_and_caddy "vaultwarden"
    fi

    if ask_yesno "Start CliproxyAPI?" "$(service_default cliproxyapi)"; then
      add_service_and_caddy "cliproxyapi"
    fi

    if ask_yesno "Start Sub-Store?" "$(service_default sub-store)"; then
      add_service_and_caddy "sub-store"
    fi
  fi

  for svc in "${caddy_candidates[@]}"; do
    seed_caddy_conf_if_available "$svc"
  done

  if [[ "$openlist_selected" == "yes" ]]; then
    if ! ssh "${VPS_ALIAS}" "test -d /home/${ANSIBLE_NEW_USER}"; then
      die "Expected /home/${ANSIBLE_NEW_USER} to exist on VPS for OpenList mount"
    fi
    ok "OpenList will mount /home/${ANSIBLE_NEW_USER} to /mnt/home"

    remote_uid="$(ssh "${VPS_ALIAS}" "id -u")"
    if [[ "$remote_uid" != "1000" ]]; then
      warn "OpenList is configured as user 1000:1000, but SSH user UID is ${remote_uid} on this VPS."
      warn "Run docker compose as a UID 1000 user, or update openlist user/volume mapping."
    fi
  fi

  apply_caddy_template_on_remote

  compose_bind_paths() {
    awk '
      /^services:/ {in_services=1; next}
      in_services && match($0, /^  [A-Za-z0-9_.-]+:/) {
        service=$1; sub(":", "", service); in_vol=0; next
      }
      in_services && /^    volumes:/ {in_vol=1; next}
      in_vol && /^      - / {
        line=$0; sub(/^      - /,"",line);
        gsub(/^["'\''"]|["'\''"]$/,"",line);
        split(line, parts, ":");
        host=parts[1];
        if (host ~ /^\./) print service "|" host;
        next
      }
      in_services && /^    [A-Za-z0-9_.-]+:/ && $0 !~ /^    volumes:/ {in_vol=0}
    ' "${SCRIPT_DIR}/docker/compose.yml"
  }

  prep_dirs=()
  add_unique_dir() {
    local val="$1"
    local item
    for item in "${prep_dirs[@]}"; do
      if [[ "$item" == "$val" ]]; then
        return 0
      fi
    done
    prep_dirs+=("$val")
  }
  while IFS='|' read -r svc host; do
    [[ -z "$svc" || -z "$host" ]] && continue
    if [[ "$svc" == "caddy" || "$svc" == "xcaddy" ]]; then
      continue
    fi
    if [[ " ${services[*]} " != *" ${svc} "* ]]; then
      continue
    fi
    local_path="${SCRIPT_DIR}/docker/${host#./}"
    if [[ -f "$local_path" ]]; then
      continue
    fi
    rel="${host#./}"
    [[ "$rel" == "." || -z "$rel" ]] && continue
    base_name="$(basename "$rel")"
    if [[ "$base_name" == *.* ]]; then
      continue
    fi
    add_unique_dir "$rel"
    parent="$(dirname "$rel")"
    [[ "$parent" != "." ]] && add_unique_dir "$parent"
  done < <(compose_bind_paths)

  if [[ "${#prep_dirs[@]}" -gt 0 ]]; then
    remote_dirs=()
    for d in "${prep_dirs[@]}"; do
      remote_dirs+=("${DOCKER_DEST}/${d}")
    done
    remote_sudo "mkdir -p ${remote_dirs[*]} && chown -R ${ANSIBLE_NEW_USER}:${ANSIBLE_NEW_USER} ${remote_dirs[*]}"
    ok "Prepared service data directories under ${DOCKER_DEST}"
  fi

  if [[ "${#services[@]}" -gt 0 ]]; then
    ssh "${VPS_ALIAS}" "cd ${DOCKER_DEST} && docker compose up -d ${services[*]}"
    ok "Docker services started"
  else
    warn "No services selected, skipping"
  fi
fi

step "Step 4 · Configuring automated backup..."
if [[ "$ENABLE_BACKUP_CRON" == "yes" ]]; then
  configure_auto_backup_cron
else
  disable_auto_backup_cron
fi

# ─────────────────────────────────────────────
#  Done
# ─────────────────────────────────────────────
echo -e "\n${GREEN}${BOLD}✔ All done! Your VPS is live.${RESET}"
echo -e "  Connect with : ${CYAN}ssh ${VPS_ALIAS}${RESET}"
echo -e "  Reload Caddy : ${CYAN}ssh ${VPS_ALIAS} 'cd ${DOCKER_DEST} && (docker compose exec caddy caddy reload --config /etc/caddy/Caddyfile || docker compose exec xcaddy caddy reload --config /etc/caddy/Caddyfile)'${RESET}\n"
echo -e "  Caddy engine : ${CYAN}${CADDY_SERVICE}${RESET} (template: ${CYAN}${DOCKER_DEST}/${CADDY_TEMPLATE}${RESET})"
echo -e "  Edit Caddyfile port/domain: ${CYAN}ssh ${VPS_ALIAS} 'vim ${DOCKER_DEST}/Caddyfile'${RESET}"
echo -e "  Proxy helper: ${CYAN}ssh -t ${VPS_ALIAS} 'cd ${DOCKER_DEST} && bash proxy_vless.sh'${RESET}"
echo -e "  Example (sing-box + REALITY): ${CYAN}ssh -t ${VPS_ALIAS} 'cd ${DOCKER_DEST} && bash proxy_vless.sh -p sb -m reality'${RESET}"
echo -e "  Example (xray + WS_TLS): ${CYAN}ssh -t ${VPS_ALIAS} 'cd ${DOCKER_DEST} && bash proxy_vless.sh -p xray -m ws_tls -d <your-domain>'${RESET}"
echo -e "  Komari passwd: ${CYAN}ssh ${VPS_ALIAS} 'docker exec komari /app/komari chpasswd -p \"PASSWORD\" && docker restart komari'${RESET}"
echo -e "  Hide a service: add \`profiles:\` to it in compose.yml, then start with ${CYAN}docker compose --profile <name> up -d <service>${RESET}"
echo
