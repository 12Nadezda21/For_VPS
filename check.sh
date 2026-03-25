#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

echo "==> Shell syntax checks"
bash -n AllinOne.sh reset-ssh.sh middle_forward.sh ops_scripts/*.sh

if [[ -f ansible/vault.yml ]]; then
  echo "==> Ansible syntax check"
  VAULT_ARGS=()
  if rg -q '^\\$ANSIBLE_VAULT' ansible/vault.yml; then
    if [[ -f ansible/.vault_pass ]]; then
      VAULT_ARGS+=(--vault-password-file ansible/.vault_pass)
    else
      VAULT_ARGS+=(--ask-vault-pass)
    fi
  fi
  env -u LC_ALL LANG=C ANSIBLE_LOCAL_TEMP=/tmp/ansible-local ANSIBLE_REMOTE_TEMP=/tmp/ansible-remote \
    ansible-playbook -i "127.0.0.1," ansible/ini.yml --syntax-check "${VAULT_ARGS[@]}"
else
  echo "==> Ansible syntax check (skipped: ansible/vault.yml missing)"
fi

echo "==> Docker Compose model check"
docker compose -f docker/compose.yml config >/dev/null

echo "All checks passed."
