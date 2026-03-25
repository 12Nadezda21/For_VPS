#!/usr/bin/env bash
# ─────────────────────────────────────────────
#  reset-ssh.sh — Restore VPS SSH to original state for redeploy testing
#  Usage: bash reset-ssh.sh -a VPS_ALIAS -o ORIGINAL_PORT
#  (connects via current hardened alias, reverts to root+password on original port)
# ─────────────────────────────────────────────
set -euo pipefail

BOLD="\033[1m"
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
CYAN="\033[0;36m"
RED="\033[0;31m"
RESET="\033[0m"

ok()   { echo -e "${GREEN}✔ $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠ $*${RESET}"; }
die()  { echo -e "${RED}✖ $*${RESET}" >&2; exit 1; }

usage() {
  echo -e "Usage: $0 -a ALIAS -o ORIGINAL_PORT [-w SUDO_PASSWORD]"
  echo -e "  -a  VPS alias in ~/.ssh/config (current hardened connection)"
  echo -e "  -o  Original root SSH port to restore (e.g. 23027)"
  echo -e "  -w  Optional sudo password for non-interactive sudo on remote user"
  exit 1
}

VPS_ALIAS="" ORIGINAL_PORT="" SUDO_PASSWORD=""

while getopts "a:o:w:" opt; do
  case $opt in
    a) VPS_ALIAS="$OPTARG" ;;
    o) ORIGINAL_PORT="$OPTARG" ;;
    w) SUDO_PASSWORD="$OPTARG" ;;
    *) usage ;;
  esac
done

[[ -z "$VPS_ALIAS" || -z "$ORIGINAL_PORT" ]] && usage
[[ "$ORIGINAL_PORT" =~ ^[0-9]{1,5}$ ]] || die "ORIGINAL_PORT must be numeric"

echo -e "\n${BOLD}╔══════════════════════════════════╗"
echo -e "║      Reset SSH to Original State      ║"
echo -e "╚══════════════════════════════════╝${RESET}\n"
warn "This will restore root login + password auth on port ${ORIGINAL_PORT}"
read -rp "  Are you sure? [y/N]: " confirm
[[ "${confirm,,}" == "y" ]] || { echo "Aborted."; exit 0; }

echo
echo -e "${CYAN}Resetting SSH config on ${VPS_ALIAS}...${RESET}"

REMOTE_RESET_SCRIPT="$(cat <<'EOF'
set -euo pipefail

run_sudo() {
  if [[ -n "${SUDO_PASSWORD:-}" ]]; then
    sudo -S -p '' "$@" <<<"$SUDO_PASSWORD"
  else
    sudo "$@"
  fi
}

run_sudo mkdir -p /etc/ssh/sshd_config.d
run_sudo rm -f /etc/ssh/sshd_config.d/00-vps-hardening.conf
echo "removed 00-vps-hardening.conf"

if [[ "$ORIGINAL_PORT" == "22" ]]; then
  tmp_reset_conf="$(mktemp)"
  cat > "$tmp_reset_conf" <<EOT
Port 22
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOT
  run_sudo install -m 0644 "$tmp_reset_conf" /etc/ssh/sshd_config.d/00-reset.conf
  rm -f "$tmp_reset_conf"
else
  tmp_reset_conf="$(mktemp)"
  cat > "$tmp_reset_conf" <<EOT
Port ${ORIGINAL_PORT}
Port 22
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
PubkeyAuthentication yes
UsePAM yes
EOT
  run_sudo install -m 0644 "$tmp_reset_conf" /etc/ssh/sshd_config.d/00-reset.conf
  rm -f "$tmp_reset_conf"
fi
echo "wrote 00-reset.conf"

if ! grep -q "^Include /etc/ssh/sshd_config.d/\\*\\.conf" /etc/ssh/sshd_config; then
  run_sudo bash -c "printf '%s\n' 'Include /etc/ssh/sshd_config.d/*.conf' >> /etc/ssh/sshd_config"
fi

if command -v sshd >/dev/null 2>&1; then
  run_sudo sshd -t
elif [[ -x /usr/sbin/sshd ]]; then
  run_sudo /usr/sbin/sshd -t
else
  echo "warning: sshd binary not found for config test"
fi

if command -v ufw >/dev/null 2>&1; then
  run_sudo ufw allow "${ORIGINAL_PORT}/tcp" >/dev/null || true
  run_sudo ufw allow 22/tcp >/dev/null || true
  run_sudo ufw reload >/dev/null 2>&1 || true
  echo "ufw rules prepared for original SSH port and 22"
else
  echo "ufw not installed, skip ufw rules"
fi

(run_sudo systemctl restart ssh || run_sudo systemctl restart sshd)
echo "sshd restarted"
EOF
)"

remote_cmd="ORIGINAL_PORT=$(printf '%q' "$ORIGINAL_PORT")"
if [[ -n "$SUDO_PASSWORD" ]]; then
  remote_cmd+=" SUDO_PASSWORD=$(printf '%q' "$SUDO_PASSWORD")"
fi
remote_cmd+=" bash -lc $(printf '%q' "$REMOTE_RESET_SCRIPT")"

ssh -tt "${VPS_ALIAS}" "$remote_cmd"

ok "SSH reset — VPS is now accepting root + password on port ${ORIGINAL_PORT}"
echo
warn "Remember to also clean up your local known_hosts if needed:"
echo -e "  ${CYAN}ssh-keygen -R \"[VPS_IP]:${ORIGINAL_PORT}\"${RESET}"
warn "If redeploy still fails, verify port reachability:"
echo -e "  ${CYAN}nc -vz <VPS_IP> ${ORIGINAL_PORT}${RESET}"
echo
