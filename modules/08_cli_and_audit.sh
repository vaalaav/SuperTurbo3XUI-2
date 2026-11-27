#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

sed "s|@BASE_DIR@|${BASE_DIR}|" "${BASE_DIR}/cli/my3xui" > /usr/local/bin/my3xui.tmp
chmod 0755 /usr/local/bin/my3xui.tmp
mv -f /usr/local/bin/my3xui.tmp /usr/local/bin/my3xui
log_ok "Установлена утилита: /usr/local/bin/my3xui"

if [[ -f "${BASE_DIR}/cli/3xui-node-geo-update" ]] && [[ -x /usr/local/x-ui/x-ui || -f /usr/local/sbin/3xui-node-geo-update ]]; then
    sed "s|@BASE_DIR@|${BASE_DIR}|" "${BASE_DIR}/cli/3xui-node-geo-update" > /usr/local/sbin/3xui-node-geo-update.tmp
    chmod 0755 /usr/local/sbin/3xui-node-geo-update.tmp
    mv -f /usr/local/sbin/3xui-node-geo-update.tmp /usr/local/sbin/3xui-node-geo-update
fi

if [[ -f "${BASE_DIR}/lib/update_antiscan.py" && -f /usr/local/sbin/update-antiscan.py ]]; then
    install -m 0755 "${BASE_DIR}/lib/update_antiscan.py" /usr/local/sbin/update-antiscan.py.tmp
    mv -f /usr/local/sbin/update-antiscan.py.tmp /usr/local/sbin/update-antiscan.py
fi

mkdir -p /etc/update-motd.d
cat <<'EOF' > /etc/update-motd.d/99-my3xui
#!/usr/bin/env bash
[[ -f /etc/3xui-node/state.env ]] || exit 0
# shellcheck disable=SC1091
source /etc/3xui-node/state.env
G='\033[0;32m'; R='\033[0;31m'; C='\033[0;36m'; B='\033[1m'; N='\033[0m'
st() { systemctl is-active --quiet "$1" && echo -e "${G}ON${N}" || echo -e "${R}OFF${N}"; }
echo -e "\n${C}------------------------------------------------${N}"
echo -e " ${B}Node:${N} ${DOMAIN} (${SERVER_IP})"
echo -e " ${B}Svc:${N}  x-ui:$(st x-ui) nginx:$(st nginx) f2b:$(st fail2ban)"
echo -e " ${B}CLI:${N}  ${C}my3xui${N} (info|creds|audit|ssh|security)"
echo -e "${C}------------------------------------------------${N}\n"
EOF
chmod +x /etc/update-motd.d/99-my3xui

# Ссылки берутся у панели — ровно те, что получит клиент в подписке (модуль 05 их уже сверил).
wait_xui_ready
ensure_xui_api_token
if LINKS=$(python3 "${BASE_DIR}/lib/xui_api.py" client-links --email=audit_system \
        --panel-port="${PANEL_PORT}" --panel-path="${PANEL_PATH}" \
        --panel-user="${PANEL_USER}" --panel-pass="${PANEL_PASS}"); then
    LINK_REALITY=$(grep -m1 'type=tcp' <<<"$LINKS" || true)
    LINK_XHTTP=$(grep -m1 'type=xhttp' <<<"$LINKS" || true)
else
    log_warn "Панель не отдала ссылки клиента — в файле учётных данных только подписка."
fi
NO_LINK="(нет — возьмите из подписки)"
SUB_JSON_URI="disabled"
[[ -n "${SUB_JSON_PATH:-}" ]] && SUB_JSON_URI="https://${DOMAIN}/${SUB_JSON_PATH}/${SUB_ID}"

INFO_FILE="/root/vps-credentials.txt"
umask 077
cat <<EOF > "$INFO_FILE"
=== 3x-ui Node Credentials ===
Домен:       ${DOMAIN} (${SERVER_IP})
SSH:         ssh -p ${SSH_PORT} root@${SERVER_IP}

Панель URL:  https://${DOMAIN}/${PANEL_PATH}/
Логин:       ${PANEL_USER}
Пароль:      ${PANEL_PASS}

Подписка:    https://${DOMAIN}/${SUB_PATH}/${SUB_ID}
JSON-подп.:  ${SUB_JSON_URI}
Happ Route:  ${HAPP_URI:-disabled}

Reality PBK: ${REALITY_PUB}
Reality SID: ${SHORT_ID_1}
XHTTP Path:  /${XHTTP_PATH}/

=== VLESS Links (audit_system) ===
[Reality]
${LINK_REALITY:-$NO_LINK}

[XHTTP]
${LINK_XHTTP:-$NO_LINK}
EOF
chmod 600 "$INFO_FILE"

my3xui creds
my3xui audit
