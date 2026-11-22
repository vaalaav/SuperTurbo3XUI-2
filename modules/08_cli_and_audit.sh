#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

install -m 0755 "${BASE_DIR}/cli/my3xui" /usr/local/bin/my3xui
log_ok "Установлена утилита: /usr/local/bin/my3xui"

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

XHTTP_EXTRA=$(python3 -c '
import json, urllib.parse
obj = {
    "noGRPCHeader": True,
    "xPaddingBytes": "200-1500",
    "xPaddingObfsMode": True,
    "xPaddingKey": "sid",
    "xPaddingPlacement": "cookie",
    "xPaddingMethod": "tokenish",
    "xmux": {"maxConnections": "3", "cMaxReuseTimes": "64-128", "hMaxRequestTimes": "600-900", "hMaxReusableSecs": "600-1200", "hKeepAlivePeriod": 0}
}
print(urllib.parse.quote(json.dumps(obj, separators=(",", ":")), safe=""))
')
XHTTP_PATH_ENC=$(python3 -c "import urllib.parse; print(urllib.parse.quote('/${XHTTP_PATH}/', safe=''))")

LINK_REALITY="vless://${CLIENT_UUID}@${DOMAIN}:443?type=tcp&security=reality&pbk=${REALITY_PUB}&fp=${UTLS_FP}&sni=${DOMAIN}&sid=${SHORT_ID_1}&spx=%2F&flow=xtls-rprx-vision#${DOMAIN}-Reality"
LINK_XHTTP="vless://${CLIENT_UUID}@${DOMAIN}:443?type=xhttp&security=tls&sni=${DOMAIN}&fp=${UTLS_FP}&alpn=h2&host=${DOMAIN}&path=${XHTTP_PATH_ENC}&mode=packet-up&extra=${XHTTP_EXTRA}#${DOMAIN}-XHTTP"

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
Happ Route:  ${HAPP_URI:-disabled}

Reality PBK: ${REALITY_PUB}
Reality SID: ${SHORT_ID_1}
XHTTP Path:  /${XHTTP_PATH}/

=== VLESS Links (user1) ===
[Reality]
${LINK_REALITY}

[XHTTP]
${LINK_XHTTP}
EOF
chmod 600 "$INFO_FILE"

my3xui creds
my3xui audit
