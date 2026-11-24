#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

XUI_VERSION="${XUI_VERSION:-$XUI_DEFAULT_VERSION}"
ENABLE_IP_LIMIT="${ENABLE_IP_LIMIT:-true}"
validate_xui_version "$XUI_VERSION"
XUI_INSTALL_LOG="/var/log/3xui-node-xui-install.log"

# Официальный установщик выбранного релиза в неинтерактивном режиме: логин, пароль, порт и путь
# задаются переменными XUI_*, TLS у панели выключен (его терминирует nginx), БД — SQLite.
# Скрипт берётся из того же тега, что и бинарник, чтобы установка была воспроизводимой.
install_xui_release() {
    local tag="$1" tmp
    tmp=$(mktemp)
    if ! curl -fsSL --retry 3 --max-time 60 "https://raw.githubusercontent.com/MHSanaei/3x-ui/${tag}/install.sh" -o "$tmp" \
        || [[ ! -s "$tmp" ]]; then
        rm -f "$tmp"
        log_err "Не удалось скачать установщик 3x-ui ${tag}. Проверьте доступ к GitHub."
    fi
    ( umask 077; : > "$XUI_INSTALL_LOG" )
    log_info "Установка 3x-ui ${tag} (лог: ${XUI_INSTALL_LOG})..."
    if ! XUI_NONINTERACTIVE=1 \
         XUI_USERNAME="$PANEL_USER" \
         XUI_PASSWORD="$PANEL_PASS" \
         XUI_PANEL_PORT="$PANEL_PORT" \
         XUI_WEB_BASE_PATH="$PANEL_PATH" \
         XUI_SSL_MODE=none \
         XUI_DB_TYPE=sqlite \
         XUI_SERVER_IP="$SERVER_IP" \
         XUI_ENABLE_FAIL2BAN="$ENABLE_IP_LIMIT" \
         bash "$tmp" "$tag" </dev/null >>"$XUI_INSTALL_LOG" 2>&1; then
        rm -f "$tmp"
        tail -n 15 "$XUI_INSTALL_LOG" >&2 || true
        log_err "Установщик 3x-ui ${tag} завершился с ошибкой — подробности в ${XUI_INSTALL_LOG}."
    fi
    rm -f "$tmp"
}

CUR_XUI=$(xui_installed_version)
if [[ -z "$CUR_XUI" ]]; then
    install_xui_release "$XUI_VERSION"
elif ! version_ge "$CUR_XUI" "$XUI_MIN_VERSION"; then
    log_warn "Установлена 3x-ui ${CUR_XUI}, проекту нужна не ниже ${XUI_MIN_VERSION} — обновляю до ${XUI_VERSION}."
    # Панель останавливается до копирования: SQLite в режиме WAL держит свежие записи в x-ui.db-wal.
    systemctl stop x-ui 2>/dev/null || true
    [[ -d /etc/x-ui ]] && log_info "Бэкап базы панели: $(backup_path /etc/x-ui "x-ui-db")"
    install_xui_release "$XUI_VERSION"
else
    log_info "3x-ui ${CUR_XUI} уже установлена — обновляю конфигурацию..."
fi

XUI_VER=$(xui_installed_version)
[[ -n "$XUI_VER" ]] || log_err "Бинарник 3x-ui не найден после установки (${XUI_BIN})."
version_ge "$XUI_VER" "$XUI_MIN_VERSION" \
    || log_err "После установки версия 3x-ui ${XUI_VER} ниже требуемой ${XUI_MIN_VERSION}."
save_var XUI_VERSION "$XUI_VERSION"
save_var ENABLE_IP_LIMIT "$ENABLE_IP_LIMIT"
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

# Настройки панели через её CLI, а не прямой записью в SQLite: CLI знает схему текущей версии.
# Панель слушает только loopback и без собственного TLS — снаружи она доступна через nginx.
systemctl stop x-ui 2>/dev/null || true
"$XUI_BIN" setting \
    -username "${PANEL_USER}" \
    -password "${PANEL_PASS}" \
    -port "${PANEL_PORT}" \
    -webBasePath "/${PANEL_PATH}/" >/dev/null
"$XUI_BIN" setting -listenIP 127.0.0.1 >/dev/null
"$XUI_BIN" cert -reset >/dev/null

systemctl enable --now x-ui >/dev/null 2>&1
systemctl restart x-ui

PANEL_UP=false
for _ in $(seq 1 40); do
    if ss -tln | grep -q "127.0.0.1:${PANEL_PORT}\b"; then
        PANEL_UP=true
        break
    fi
    sleep 0.5
done
$PANEL_UP || log_err "Панель 3x-ui не начала слушать 127.0.0.1:${PANEL_PORT} — проверьте journalctl -u x-ui."
sleep 1
ensure_xui_api_token

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

set -a; source /etc/3xui-node/state.env; set +a
python3 "${BASE_DIR}/lib/xui_v311_post.py"
systemctl restart x-ui
