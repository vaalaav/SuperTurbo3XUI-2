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

systemctl enable x-ui >/dev/null 2>&1
restart_xui
ensure_xui_api_token

# Все geo-файлы обновляются при каждой установке штатным механизмом панели (сверка с дайджестом
# релиза, атомарная замена) — до настройки шаблона, чтобы его правила проверялись по свежим файлам.
log_info "Обновление geo-файлов 3x-ui (Loyalsoldier, IR, RU)..."
python3 "${BASE_DIR}/lib/xui_api.py" update-geo \
    --panel-port="${PANEL_PORT}" --panel-path="${PANEL_PATH}" \
    --panel-user="${PANEL_USER}" --panel-pass="${PANEL_PASS}" >/dev/null \
    || log_err "Не удалось обновить geo-файлы 3x-ui — проверьте доступ сервера к GitHub."
log_ok "Geo-файлы 3x-ui обновлены."

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
    --panel-port="${PANEL_PORT}" \
    --panel-path="${PANEL_PATH}" \
    --panel-user="${PANEL_USER}" \
    --panel-pass="${PANEL_PASS}" \
    --sub-port="${SUB_PORT}" \
    --sub-path="${SUB_PATH}" \
    --domain="${DOMAIN}" \
    --server-ip="${SERVER_IP}" \
    --reality-priv="${REALITY_PRIV}" \
    --reality-pub="${REALITY_PUB}" \
    --utls-fp="${UTLS_FP}" \
    --xhttp-path="${XHTTP_PATH}" \
    --client-uuid="${CLIENT_UUID}" \
    --sub-id="${SUB_ID}" \
    --short-id-1="${SHORT_ID_1}" \
    --short-id-2="${SHORT_ID_2}" \
    --enable-happ="${ENABLE_HAPP}" \
    --enable-geo-mirror="${ENABLE_GEO_MIRROR}" \
    --geo-path="${GEO_PATH}")

log_ok "API 3x-ui: ${API_RES}"
HAPP_URI=$(echo "$API_RES" | jq -r '.happ_uri // ""' 2>/dev/null || true)
[[ -n "$HAPP_URI" ]] && save_var HAPP_URI "$HAPP_URI"
restart_xui

if [[ -f /usr/local/x-ui/bin/config.json ]]; then
    if "$XRAY_BIN" run -test -config /usr/local/x-ui/bin/config.json >/dev/null 2>&1; then
        log_ok "Конфигурация Xray прошла проверку (xray run -test)."
    else
        log_warn "xray run -test вернул предупреждение — проверьте journalctl -u x-ui."
    fi
fi

set -a; source /etc/3xui-node/state.env; set +a
python3 "${BASE_DIR}/lib/xui_v311_post.py"
# Модули после 05 сразу обращаются к API, поэтому модуль завершается только когда панель отвечает.
restart_xui

# Ежедневное обновление geo-файлов и зеркала для Happ (вместо прежнего cron модуля 04).
sed "s|@BASE_DIR@|${BASE_DIR}|" "${BASE_DIR}/cli/3xui-node-geo-update" > /usr/local/sbin/3xui-node-geo-update
chmod 755 /usr/local/sbin/3xui-node-geo-update
cat <<'EOF' > /etc/systemd/system/3xui-node-geo-update.service
[Unit]
Description=Обновление geo-файлов 3x-ui и зеркала для Happ
After=network-online.target x-ui.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/3xui-node-geo-update
EOF
cat <<'EOF' > /etc/systemd/system/3xui-node-geo-update.timer
[Unit]
Description=Ежедневное обновление geo-файлов 3x-ui

[Timer]
OnCalendar=*-*-* 04:20:00
RandomizedDelaySec=45min
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now 3xui-node-geo-update.timer >/dev/null 2>&1
rm -f /usr/local/sbin/update-geo-mirror.sh /etc/cron.d/update-geo-mirror
/usr/local/sbin/3xui-node-geo-update --mirror-only
