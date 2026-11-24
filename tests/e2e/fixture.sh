#!/usr/bin/env bash
# Готовит «чистый сервер» для сквозного теста модуля 05: без 3x-ui, со state.env и Fail2ban,
# как после модулей 01–04. РАЗРУШИТЕЛЬНО: удаляет 3x-ui, /etc/x-ui и /etc/3xui-node.
# Аргументы: $1 — ENABLE_IP_LIMIT (true/false, по умолчанию true), $2 — PANEL_PASS (необязательно).
set -euo pipefail

[[ "${E2E_DISPOSABLE:-}" == "1" ]] || { echo "Только для одноразовой машины: задайте E2E_DISPOSABLE=1." >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Нужен root." >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IP_LIMIT="${1:-true}"
# По умолчанию пароль в формате генератора модуля 01 — со спецсимволами.
PASS="${2:-Kq7!x#P2&m_Z@9w^R+e=}"

systemctl stop x-ui 2>/dev/null || true
rm -rf /usr/local/x-ui /etc/x-ui /usr/bin/x-ui /etc/systemd/system/x-ui.service /etc/systemd/system/x-ui.service.d \
       /etc/3xui-node /root/3xui-node-backups /var/log/3xui-node-install.log /var/log/3xui-node-xui-install.log \
       /etc/fail2ban/jail.d/3x-ipl.conf /etc/fail2ban/jail.d/3x-ipl-backend.conf \
       /etc/fail2ban/filter.d/3x-ipl.conf /etc/fail2ban/action.d/3x-ipl.conf /var/log/x-ui /etc/default/x-ui
systemctl daemon-reload

if ! command -v fail2ban-client >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fail2ban >/dev/null
fi
mkdir -p /var/log/nginx
touch /var/log/nginx/access.log /var/log/auth.log
# Fail2ban как после модуля 03; sshd на polling, чтобы конфигурация работала и без журнала systemd.
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 4
banaction = nftables-multiport

[sshd]
enabled = true
port = 22
backend = polling
logpath = /var/log/auth.log

[nginx-botsearch]
enabled = true
port = http,https
backend = polling
logpath = /var/log/nginx/access.log
maxretry = 10
findtime = 5m
bantime = 12h
EOF
systemctl restart fail2ban

# shellcheck source=lib/common.sh
source "${REPO}/lib/common.sh"
init_state
save_var SERVER_IP 203.0.113.10
save_var DOMAIN node.example.com
save_var SSH_PORT 22
save_var PANEL_USER uadmin7k2q
save_var PANEL_PASS "$PASS"
save_var PANEL_PORT 41234
save_var PANEL_PATH 3f9a0c1b2d4e5f607182
save_var SUB_PORT 48123
save_var SUB_PATH 9b8a7c6d5e4f3a2b1c0d9e8f
save_var XHTTP_PATH api/v2/a1b2c3d4e5f6
save_var GEO_PATH assets/geo/abcde12345
save_var UTLS_FP chrome
save_var CLIENT_UUID 11111111-2222-4333-8444-555555555555
save_var SUB_ID subid0001
save_var ENABLE_HAPP true
save_var ENABLE_GEO_MIRROR false
save_var ENABLE_IP_LIMIT "$IP_LIMIT"
echo "fixture: ENABLE_IP_LIMIT=${IP_LIMIT}"
