# tools-install

Script / config cài tool cho server. Mỗi tool một thư mục.

| Thư mục | Tool |
| --- | --- |
| `cockpit-service/` | Cockpit + plugin |
| `kaneo/` | [Kaneo](https://github.com/usekaneo/kaneo) (quản lý task), Docker Compose |

## Cockpit

```bash
cd cockpit-service
sudo ./run.sh                 # menu
sudo ./run.sh -y install      # install | update | uninstall | restart | apply | status
```

Config trong `cockpit.config.yaml` (port, domains, reverse proxy, plugins). Sửa xong chạy `sudo ./run.sh apply`.

**Plugin cài qua `run.sh`:** cockpit-files, cockpit-compose.

**Plugin tự cài** (cài Cockpit trước):

- [pm2-monitor](https://github.com/fenita201/pm2-monitor): chạy bằng user PM2, không sudo, Node >= 20.19.
  ```bash
  ./start.sh && ./install-cockpit-plugin.sh
  ```
- [cockpit-plugin-agent-cli](https://github.com/fenita201/cockpit-plugin-agent-cli) (Claude Code / Codex): Ubuntu, cần Node 22+ system-wide.
  ```bash
  sudo ./cockpit/install.sh     # --yes, --skip-cli
  ```

## Kaneo

> ⚠️ Đổi `POSTGRES_PASSWORD` và `AUTH_SECRET` trong `.env` trước khi chạy (`openssl rand -hex 32`).

```bash
cd kaneo
docker compose up -d
```

Mặc định port `5173`, tắt đăng ký / guest / tạo workspace (xem `.env`).
