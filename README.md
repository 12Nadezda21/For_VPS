# IniVPS
用于通过 Ansible + Docker Compose 一键初始化 VPS，并通过 Caddy 统一反代。

**核心入口**：`AllinOne.sh`（Step 1 初始化 + Step 2 同步 + Step 3 启动 + Step 4 备份定时）

**运行目录**：所有运行文件都在 `/srv/compose`，方便迁移与备份。

---

**快速开始**
1. 准备本地环境：需要 `bash`、`ssh`、`ansible-playbook`。建议先运行 `./check.sh` 做本地语法检查。
2. 配置变量与密码：编辑 `ansible/vars.yml`；编辑 `ansible/vault.yml`（明文占位符需替换为真实密码）；如需加密运行 `ansible-vault encrypt ansible/vault.yml`；如使用 Vault 且不想交互输入，复制 `ansible/.vault_pass.example` 到 `ansible/.vault_pass`（不要提交到仓库）；复制 `docker/.env.example` 到 `docker/.env` 并设置 `VAULTWARDEN_ADMIN_TOKEN`。
3. 一键初始化：
```bash
bash AllinOne.sh -a <VPS_ALIAS> -i <VPS_IP> -p <SSH_PORT> -s <VPS_ROOT_PASSWORD>
```

4. 需要跳过步骤时：
```bash
bash AllinOne.sh -a <VPS_ALIAS> -i <VPS_IP> -k -d -u
```

**常用参数**
```text
Usage: AllinOne.sh -a ALIAS -i IP [-p PORT] [-s PASSWORD] [-w SUDO_PASSWORD] [-k] [-d] [-u]
  -a  VPS 别名（写入 ~/.ssh/config）
  -i  VPS IP
  -p  Root SSH 端口（Step 1 需要）
  -s  Root SSH 密码（Step 1 需要）
  -w  sudo 密码（可选，用于非交互 sudo）
  -k  跳过 Step 1（Ansible 初始化）
  -d  跳过 Step 2（Docker 同步）
  -u  跳过 Step 3（Docker 启动）
```

---

**服务说明**
- Caddy：反向代理入口（`caddy` 或 `xcaddy`）。
- Komari：监控面板（`127.0.0.1:25774`）。
- OpenList：文件列表（`127.0.0.1:5244`）。
- EasyImage：图床（`127.0.0.1:8080`）。
- Vaultwarden：密码管理（`127.0.0.1:8000`）。
- CliproxyAPI：本地 API 网关（`127.0.0.1:8317`）。
- Sub-Store：订阅存储（`network_mode: host`，端口 `9876`）。

启动时会提示是否开启各服务。若服务存在模板，脚本会把 `caddy-sites/*.conf.example` 同步到 VPS，提示你改域名后再启用。

---

**代理助手（VLESS/Reality/WS）**
所有代理脚本在 `ops_scripts/`，Step 2 会同步到 VPS：
```bash
ssh <VPS_ALIAS>
cd /srv/compose
bash proxy_vless.sh
```

带参数示例：
```bash
bash proxy_vless.sh -p sb -m reality
bash proxy_vless.sh -p xray -m ws_tls -d <YOUR_DOMAIN>
```

---

**中转转发（Middle Forwarding）**
```bash
sudo ./middle_forward.sh start <TARGET_IP> <LOCAL_PORT> <TARGET_PORT>
```
停止：
```bash
sudo ./middle_forward.sh end
```

---

**本地检查**
```bash
./check.sh
```

---

**发布前必做**
- 替换 `ansible/vars.yml` 与 `ansible/vault.yml` 中的占位符。
- 确保 `ansible/.vault_pass`、`docker/.env` 不被提交。
- 部署前确认域名与端口是你的真实配置。
