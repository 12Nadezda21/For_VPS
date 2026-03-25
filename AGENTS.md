# Repository Guidelines

## Project Structure & Module Organization
This repository bootstraps and operates a VPS with Ansible + Docker Compose. `AllinOne.sh` is the orchestration entrypoint (Step 1 init, Step 2 sync, Step 3 service up, Step 4 backup cron). `ansible/ini.yml` is the active two-play provisioning playbook; `ansible/vars.yml` stores non-secret defaults; `ansible/vault.yml` stores secrets; `ansible/ops_defaults.env.j2` renders runtime defaults into `/srv/compose/ops_defaults.env`. Runtime stack files are under `docker/` (notably `compose.yml`, `Caddyfile.template`, `XCaddyfile.template`). Service reverse-proxy examples are in `caddy-sites/*.conf.example`. Operational scripts synced to VPS root are in `ops_scripts/` (`proxy_vless.sh`, `compose_backup.sh`, `openclaw_backup.sh`). Utility helpers include `reset-ssh.sh` and `middle_forward.sh`.

## Build, Test, and Development Commands
Use the repository scripts directly; there is no Makefile.

- `bash AllinOne.sh -a <alias> -i <ip> -p <root_port> -s <root_password> [-w <sudo_password>]`: full bootstrap.
- `bash AllinOne.sh -a <alias> -i <ip> -k [-d] [-u]`: rerun mode for already-initialized hosts.
- `ansible-playbook -i "<ip>," ansible/ini.yml --syntax-check --vault-password-file ansible/.vault_pass`: validate playbook before changes land.
- `docker compose -f docker/compose.yml config`: render and validate the Compose file.
- `bash -n AllinOne.sh reset-ssh.sh middle_forward.sh ops_scripts/*.sh`: catch shell syntax errors quickly.
- `./check.sh`: run shell + Ansible + Compose checks in one command.

## Coding Style & Naming Conventions
Shell scripts should use `#!/usr/bin/env bash` with `set -euo pipefail`. Keep environment-style variables uppercase (`VPS_ALIAS`, `DOCKER_DEST`) and Ansible variables lowercase snake_case (`new_user`, `compose_root`). Match the indentation style of the file you touch, and keep comments brief and operational. Name new Caddy templates as `*.conf.example` and keep Ansible task names imperative and descriptive.

## Testing Guidelines
There is no dedicated automated test suite yet, so every change should include syntax validation. For Ansible changes, run `--syntax-check` and, when safe, `ansible-playbook ... --check` against a non-production host. For Docker changes, validate with `docker compose ... config` and keep ports bound to `127.0.0.1` unless public exposure is intentional.

## Commit & Pull Request Guidelines
Recent history uses short prefixes such as `Add:`, `Added:`, `Update:`, and `Fix:` followed by a concise summary. Keep commit messages in that style and scoped to one change. Pull requests should state the affected area (`ansible`, `docker`, `caddy`, or scripts), list the commands used for validation, and call out any changes to secrets, ports, domains, or backup behavior.

## Security & Configuration Tips
Do not commit live secrets, replacement `.vault_pass` files, or unredacted values from `vault.yml` and runtime `.env` files. Prefer examples/templates in docs, and scrub IPs, passwords, tokens, and WebDAV credentials from logs or PR text. Keep externally exposed ports intentional; default to localhost binds in `docker/compose.yml` unless public exposure is required.
