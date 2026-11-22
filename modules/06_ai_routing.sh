#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

if [[ "${AI_MODE:-none}" == "none" ]]; then
    log_info "AI-модуль отключён (AI_MODE=none), шаг пропущен."
    exit 0
fi

WARP_PRIV=""
WARP_PEER_PUB=""
WARP_V4=""
WARP_V6=""
WARP_RESERVED=""

if [[ "$AI_MODE" == "warp" || "$AI_MODE" == "combo" ]]; then
    log_info "Регистрация встроенного профиля Cloudflare WARP..."
    XRAY_BIN=$(find /usr/local/x-ui/bin -maxdepth 1 -name "xray-linux-*" -type f | head -n 1)
    WARP_DATA=$(python3 - "$XRAY_BIN" <<'PYEOF'
import base64
import datetime
import json
import subprocess
import sys
import urllib.request

xray_bin = sys.argv[1]
out = subprocess.check_output([xray_bin, "wg"], text=True)
priv = pub = ""
for line in out.splitlines():
    if "Private" in line:
        priv = line.split(":", 1)[1].strip()
    elif "Public" in line:
        pub = line.split(":", 1)[1].strip()

payload = {
    "key": pub,
    "install_id": "",
    "fcm_token": "",
    "tos": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"),
    "model": "PC",
    "serial_number": "",
    "locale": "en_US",
}
req = urllib.request.Request(
    "https://api.cloudflareclient.com/v0a2158/reg",
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json", "User-Agent": "okhttp/3.12.1"},
    method="POST",
)
with urllib.request.urlopen(req, timeout=20) as resp:
    res = json.loads(resp.read().decode("utf-8"))

cfg = res["config"]
client_id = cfg["client_id"]
reserved = list(base64.b64decode(client_id))
print(json.dumps({
    "priv": priv,
    "peer_pub": cfg["peers"][0]["public_key"],
    "v4": cfg["interface"]["addresses"]["v4"] + "/32",
    "v6": cfg["interface"]["addresses"]["v6"] + "/128",
    "reserved": ",".join(str(x) for x in reserved),
}))
PYEOF
    ) || log_warn "Не удалось зарегистрировать профиль WARP."

    if [[ -n "${WARP_DATA:-}" ]]; then
        WARP_PRIV=$(echo "$WARP_DATA" | jq -r '.priv')
        WARP_PEER_PUB=$(echo "$WARP_DATA" | jq -r '.peer_pub')
        WARP_V4=$(echo "$WARP_DATA" | jq -r '.v4')
        WARP_V6=$(echo "$WARP_DATA" | jq -r '.v6')
        WARP_RESERVED=$(echo "$WARP_DATA" | jq -r '.reserved')
        log_ok "Профиль WARP зарегистрирован (${WARP_V4})."
    fi
fi

if [[ "$AI_MODE" == "psiphon" || "$AI_MODE" == "combo" ]]; then
    log_info "Развёртывание Psiphon (Chara-Freedom/vps-psiphon, регион ${PSIPHON_REGION})..."
    if ! command -v docker >/dev/null 2>&1; then
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        systemctl enable --now docker >/dev/null 2>&1
    fi
    command -v git >/dev/null 2>&1 || apt-get install -y -qq git

    PSIPHON_DIR="/opt/vps-psiphon"
    if [[ -d "${PSIPHON_DIR}/.git" ]]; then
        git -C "$PSIPHON_DIR" pull -q || true
    else
        rm -rf "$PSIPHON_DIR"
        git clone -q https://github.com/Chara-Freedom/vps-psiphon.git "$PSIPHON_DIR"
    fi

    docker build -q -t vps-psiphon:local "$PSIPHON_DIR" >/dev/null
    docker rm -f vps-psiphon >/dev/null 2>&1 || true

    docker run -d \
        --name vps-psiphon \
        --restart unless-stopped \
        --network host \
        vps-psiphon:local \
        --region "${PSIPHON_REGION}" \
        --socks-listen "127.0.0.1:${PSIPHON_PORT}" \
        --impersonate \
        --no-http >/dev/null

    sleep 4
    if ss -tln | grep -q "127.0.0.1:${PSIPHON_PORT}"; then
        log_ok "Psiphon SOCKS5 запущен на 127.0.0.1:${PSIPHON_PORT}."
    else
        log_warn "Psiphon ещё инициализируется — проверьте docker logs vps-psiphon."
    fi
fi

log_info "Интеграция AI-маршрутов (${AI_MODE}) в 3x-ui..."
python3 "${BASE_DIR}/lib/xui_api.py" configure-ai \
    --panel-port "${PANEL_PORT}" \
    --panel-path "${PANEL_PATH}" \
    --panel-user "${PANEL_USER}" \
    --panel-pass "${PANEL_PASS}" \
    --ai-mode "${AI_MODE}" \
    --warp-priv-key "${WARP_PRIV}" \
    --warp-peer-pub "${WARP_PEER_PUB}" \
    --warp-v4 "${WARP_V4}" \
    --warp-v6 "${WARP_V6}" \
    --warp-reserved "${WARP_RESERVED}" \
    --psiphon-port "${PSIPHON_PORT}" \
    --psiphon-ip-detect "${PSIPHON_IP_DETECT}" >/dev/null

systemctl restart x-ui
sleep 2
log_ok "AI-маршрутизация (${AI_MODE}) применена."
