# IniVPS
One-command VPS bootstrap using Ansible + Docker Compose, fronted by Caddy.

**Entry point**: `AllinOne.sh` (Step 1 init + Step 2 sync + Step 3 up + Step 4 backup cron)

**Runtime root**: all services live under `/srv/compose` for easy backup and migration.

---

**Quick Start**
1. Local prerequisites: `bash`, `ssh`, `ansible-playbook`. Run `./check.sh` for a quick local sanity check.
2. Configure variables and secrets: edit `ansible/vars.yml`; edit `ansible/vault.yml` (plaintext placeholders must be replaced); optionally encrypt with `ansible-vault encrypt ansible/vault.yml`; if encrypted and you want non-interactive runs, copy `ansible/.vault_pass.example` to `ansible/.vault_pass` (do not commit); copy `docker/.env.example` to `docker/.env` and set `VAULTWARDEN_ADMIN_TOKEN`.
3. Run once:
```bash
bash AllinOne.sh -a <VPS_ALIAS> -i <VPS_IP> -p <SSH_PORT> -s <VPS_ROOT_PASSWORD>
```
4. Skip steps when needed:
```bash
bash AllinOne.sh -a <VPS_ALIAS> -i <VPS_IP> -k -d -u
```

**Usage**
```text
Usage: AllinOne.sh -a ALIAS -i IP [-p PORT] [-s PASSWORD] [-w SUDO_PASSWORD] [-k] [-d] [-u]
  -a  VPS alias (written to ~/.ssh/config)
  -i  VPS IP
  -p  Root SSH port (required for Step 1)
  -s  Root SSH password (required for Step 1)
  -w  Sudo password (optional for non-interactive sudo)
  -k  Skip Step 1 (Ansible init)
  -d  Skip Step 2 (Docker sync)
  -u  Skip Step 3 (Docker up)
```

---

**Services**
- Caddy: reverse proxy entry (`caddy` or `xcaddy`).
- Komari: monitoring (`127.0.0.1:25774`).
- OpenList: file index (`127.0.0.1:5244`).
- EasyImage: image hosting (`127.0.0.1:8080`).
- Vaultwarden: password vault (`127.0.0.1:8000`).
- CliproxyAPI: local API gateway (`127.0.0.1:8317`).
- Sub-Store: subscription backend (`network_mode: host`, port `9876`).

During Step 3 you will be prompted to start services. If a service template exists, it is synced from `caddy-sites/*.conf.example` and you will be reminded to edit domains before enabling.

---

**Proxy Helper (VLESS/Reality/WS)**
Scripts live in `ops_scripts/` and are synced in Step 2:
```bash
ssh <VPS_ALIAS>
cd /srv/compose
bash proxy_vless.sh
```

With args:
```bash
bash proxy_vless.sh -p sb -m reality
bash proxy_vless.sh -p xray -m ws_tls -d <YOUR_DOMAIN>
```

---

**Middle Forwarding**
```bash
sudo ./middle_forward.sh start <TARGET_IP> <LOCAL_PORT> <TARGET_PORT>
```
Stop:
```bash
sudo ./middle_forward.sh end
```

---

**Local Checks**
```bash
./check.sh
```

---

**Before You Publish**
- Replace placeholders in `ansible/vars.yml` and `ansible/vault.yml`.
- Make sure `ansible/.vault_pass` and `docker/.env` are not committed.
- Confirm domains and ports match your real deployment.
