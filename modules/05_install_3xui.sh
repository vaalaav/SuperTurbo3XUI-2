#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

if [[ ! -x /usr/local/x-ui/x-ui ]]; then
    log_info "Установка официальной панели 3x-ui (MHSanaei)..."
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) <<EOF
n
EOF
else
    log_info "3x-ui уже установлена — обновляю конфигурацию..."
fi

XUI_VER=$(/usr/local/x-ui/x-ui -v 2>/dev/null | head -n 1 || echo "unknown")
log_ok "Версия 3x-ui: ${XUI_VER}"

mkdir -p /etc/systemd/system/x-ui.service.d
cat <<'EOF' > /etc/systemd/system/x-ui.service.d/20-local.conf
[Service]
LimitNOFILE=524288
EOF
systemctl daemon-reload

log_info "Загрузка geosite_RU.dat / geoip_RU.dat..."
mkdir -p /usr/local/x-ui/bin
curl -fsSL --max-time 45 "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" \
    -o /usr/local/x-ui/bin/geosite_RU.dat 2>/dev/null || log_warn "Не удалось скачать geosite_RU.dat"
curl -fsSL --max-time 45 "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat" \
    -o /usr/local/x-ui/bin/geoip_RU.dat 2>/dev/null || log_warn "Не удалось скачать geoip_RU.dat"

systemctl stop x-ui 2>/dev/null || true
/usr/local/x-ui/x-ui setting \
    -username "${PANEL_USER}" \
    -password "${PANEL_PASS}" \
    -port "${PANEL_PORT}" \
    -webBasePath "/${PANEL_PATH}/" >/dev/null

python3 - <<'PYEOF'
import sqlite3
conn = sqlite3.connect("/etc/x-ui/x-ui.db")
cur = conn.cursor()
for k, v in [("webListen", "127.0.0.1"), ("webCertFile", ""), ("webKeyFile", "")]:
    cur.execute("SELECT id FROM settings WHERE key = ?", (k,))
    if cur.fetchone():
        cur.execute("UPDATE settings SET value = ? WHERE key = ?", (v, k))
    else:
        cur.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, v))
conn.commit()
conn.close()
PYEOF

systemctl enable --now x-ui >/dev/null 2>&1
systemctl restart x-ui

for _ in $(seq 1 20); do
    if ss -tln | grep -q "127.0.0.1:${PANEL_PORT}"; then
        break
    fi
    sleep 0.5
done
sleep 1

XRAY_BIN=$(find /usr/local/x-ui/bin -maxdepth 1 -name "xray-linux-*" -type f | head -n 1)
[[ -n "$XRAY_BIN" ]] || log_err "Бинарник Xray не найден в /usr/local/x-ui/bin."

KEY_OUT=$("$XRAY_BIN" x25519)
REALITY_PRIV=$(echo "$KEY_OUT" | awk -F: '/Private/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
REALITY_PUB=$(echo "$KEY_OUT" | awk -F: '/Public|Password/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')
[[ -n "$REALITY_PRIV" && -n "$REALITY_PUB" ]] || log_err "Не удалось сгенерировать ключи X25519."

SHORT_ID_1=$(openssl rand -hex 4)
SHORT_ID_2=$(openssl rand -hex 8)

save_var REALITY_PRIV "$REALITY_PRIV"
save_var REALITY_PUB "$REALITY_PUB"
save_var SHORT_ID_1 "$SHORT_ID_1"
save_var SHORT_ID_2 "$SHORT_ID_2"

log_info "Настройка инбаундов, клиента и роутинга через REST API 3x-ui..."
API_RES=$(python3 "${BASE_DIR}/lib/xui_api.py" setup-node \
    --panel-port "${PANEL_PORT}" \
    --panel-path "${PANEL_PATH}" \
    --panel-user "${PANEL_USER}" \
    --panel-pass "${PANEL_PASS}" \
    --sub-port "${SUB_PORT}" \
    --sub-path "${SUB_PATH}" \
    --domain "${DOMAIN}" \
    --server-ip "${SERVER_IP}" \
    --reality-priv "${REALITY_PRIV}" \
    --reality-pub "${REALITY_PUB}" \
    --utls-fp "${UTLS_FP}" \
    --xhttp-path "${XHTTP_PATH}" \
    --client-uuid "${CLIENT_UUID}" \
    --sub-id "${SUB_ID}" \
    --short-id-1 "${SHORT_ID_1}" \
    --short-id-2 "${SHORT_ID_2}" \
    --enable-happ "${ENABLE_HAPP}" \
    --enable-geo-mirror "${ENABLE_GEO_MIRROR}" \
    --geo-path "${GEO_PATH}")

log_ok "API 3x-ui: ${API_RES}"
HAPP_URI=$(echo "$API_RES" | jq -r '.happ_uri // ""' 2>/dev/null || true)
[[ -n "$HAPP_URI" ]] && save_var HAPP_URI "$HAPP_URI"
systemctl restart x-ui
sleep 2

if [[ -f /usr/local/x-ui/bin/config.json ]]; then
    if "$XRAY_BIN" run -test -config /usr/local/x-ui/bin/config.json >/dev/null 2>&1; then
        log_ok "Конфигурация Xray прошла проверку (xray run -test)."
    else
        log_warn "xray run -test вернул предупреждение — проверьте journalctl -u x-ui."
    fi
fi
