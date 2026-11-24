#!/usr/bin/env bash
# Сквозные сценарии модуля 05 на одноразовой машине с systemd (CI-раннер или тестовая VM).
# РАЗРУШИТЕЛЬНО: переустанавливает 3x-ui. Запуск: sudo E2E_DISPOSABLE=1 bash tests/e2e/module05.sh <сценарий>
#   fresh       — чистая установка, повторный запуск, восстановление удалённого API-токена
#   upgrade     — на сервере 3x-ui 3.10.2 с данными; модуль обновляет её с бэкапом и сохраняет данные
#   no-ip-limit — IP Limit и зеркало geo выключены, пароль панели начинается с «-»
#   psiphon     — модуль 06 в режиме psiphon: настоящий туннель, маршруты Gemini в Xray
set -euo pipefail

[[ "${E2E_DISPOSABLE:-}" == "1" ]] || { echo "Только для одноразовой машины: задайте E2E_DISPOSABLE=1." >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Нужен root." >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E="${REPO}/tests/e2e"
LOG_DIR="${E2E_LOG_DIR:-/tmp/e2e-logs}"
mkdir -p "$LOG_DIR"
OLD_XUI_TAG="v3.10.2"

step() { echo; echo "=== $(date -u +%H:%M:%S) $*"; }
die()  { echo "ОШИБКА: $*" >&2; exit 1; }

run_module05() {
    local name="$1"
    echo "  ..   $(date -u +%H:%M:%S) модуль 05 (${name})"
    if ! bash "${REPO}/install.sh" --only 05_install_3xui >"${LOG_DIR}/${name}.log" 2>&1; then
        tail -n 40 "${LOG_DIR}/${name}.log" >&2
        [[ -f /var/log/3xui-node-xui-install.log ]] && tail -n 20 /var/log/3xui-node-xui-install.log >&2
        die "модуль 05 завершился с ошибкой (${name})"
    fi
    echo "  ..   $(date -u +%H:%M:%S) модуль 05 (${name}) завершён"
    sed 's/\x1b\[[0-9;]*m//g' "${LOG_DIR}/${name}.log" | grep -aE '\[(OK|WARN|INFO)\]' | cut -c1-160 || true
}

state_get() { grep "^$1=" /etc/3xui-node/state.env | cut -d= -f2-; }

panel_api() {  # $1 — токен, $2 — путь, дальше — аргументы curl
    local tok="$1" path="$2"; shift 2
    # shellcheck source=/dev/null
    source /etc/3xui-node/state.env
    curl -s --max-time 10 -H "Authorization: Bearer ${tok}" "http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}${path}" "$@"
}

scenario_fresh() {
    step "чистая установка"
    bash "${E2E}/fixture.sh" true
    run_module05 fresh
    bash "${E2E}/check.sh"

    step "ручной запуск обновления geo-файлов (как по таймеру)"
    systemctl start 3xui-node-geo-update.service || die "запуск 3xui-node-geo-update завершился ошибкой"
    systemctl is-failed --quiet 3xui-node-geo-update.service && die "юнит 3xui-node-geo-update в состоянии failed"
    echo "  ok   обновление geo-файлов по таймеру отработало"

    step "повторный запуск: установщик не запускается, токен прежний"
    local tok1 mtime1
    tok1=$(state_get XUI_API_TOKEN)
    mtime1=$(stat -c %Y /var/log/3xui-node-xui-install.log)
    run_module05 rerun
    grep -q "уже установлена" "${LOG_DIR}/rerun.log" || die "при повторном запуске модуль не распознал установленную 3x-ui"
    [[ "$(stat -c %Y /var/log/3xui-node-xui-install.log)" == "$mtime1" ]] || die "установщик запускался повторно"
    [[ "$(state_get XUI_API_TOKEN)" == "$tok1" ]] || die "токен перевыпущен без причины"
    echo "  ok   установщик не запускался, токен прежний"
    bash "${E2E}/check.sh"

    step "токен 3xui-node удалён в панели: модуль выпускает новый с тем же именем"
    local install_tok id
    install_tok=$(grep '^XUI_API_TOKEN=' /etc/x-ui/install-result.env | cut -d= -f2-)
    id=$(panel_api "$install_tok" /panel/api/setting/apiTokens | jq -r '.obj[] | select(.name == "3xui-node") | .id')
    panel_api "$install_tok" "/panel/api/setting/apiTokens/delete/${id}" -X POST \
        -H 'Content-Type: application/json' -d '{"expectedScope":"admin"}' | jq -e '.success' >/dev/null \
        || die "не удалось удалить токен через API"
    [[ "$(panel_api "$tok1" /panel/api/server/status -o /dev/null -w '%{http_code}')" == 401 ]] \
        || die "удалённый токен всё ещё принимается (контроль)"
    run_module05 token
    grep -q "отклонён панелью" "${LOG_DIR}/token.log" || die "модуль не заметил отозванный токен"
    [[ "$(state_get XUI_API_TOKEN)" != "$tok1" ]] || die "в state.env остался отозванный токен"
    echo "  ok   выпущен и сохранён новый токен"
    bash "${E2E}/check.sh"
}

scenario_upgrade() {
    step "на сервере 3x-ui ${OLD_XUI_TAG} с пользовательским инбаундом"
    bash "${E2E}/fixture.sh" true
    local inst old_tok port path
    inst=$(mktemp)
    curl -fsSL --retry 3 "https://raw.githubusercontent.com/MHSanaei/3x-ui/${OLD_XUI_TAG}/install.sh" -o "$inst"
    XUI_NONINTERACTIVE=1 XUI_ENABLE_FAIL2BAN=false bash "$inst" "$OLD_XUI_TAG" </dev/null >"${LOG_DIR}/old-install.log" 2>&1 \
        || { tail -n 30 "${LOG_DIR}/old-install.log" >&2; die "не удалось поставить ${OLD_XUI_TAG}"; }
    rm -f "$inst"
    [[ "$(/usr/local/x-ui/x-ui -v)" == "${OLD_XUI_TAG#v}" ]] || die "ожидалась версия ${OLD_XUI_TAG#v}"
    old_tok=$(/usr/local/x-ui/x-ui setting -getApiToken -tokenName e2e-old | awk '/^apiToken:/ {print $2}')
    port=$(/usr/local/x-ui/x-ui setting -show true | awk '/^port:/ {print $2}')
    path=$(/usr/local/x-ui/x-ui setting -show true | awk '/^webBasePath:/ {print $2}')
    # Установщик последним шагом перезапускает панель, а порт она открывает примерно через секунду.
    local code="000"
    for _ in $(seq 1 60); do
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}${path}" || true)
        [[ "$code" != "000" ]] && break
        sleep 0.5
    done
    [[ "$code" != "000" ]] || die "старая панель не ответила после установки"
    curl -s --max-time 10 -X POST -H "Authorization: Bearer ${old_tok}" -H 'Content-Type: application/json' \
        "http://127.0.0.1:${port}${path}panel/api/inbounds/add" -d '{"up":0,"down":0,"total":0,"remark":"keep-me",
        "enable":true,"expiryTime":0,"listen":"127.0.0.1","port":30999,"protocol":"vless","tag":"keep-me",
        "settings":"{\"clients\":[],\"decryption\":\"none\",\"fallbacks\":[]}",
        "streamSettings":"{\"network\":\"tcp\",\"security\":\"none\",\"tcpSettings\":{\"header\":{\"type\":\"none\"}}}",
        "sniffing":"{\"enabled\":false}"}' | jq -e '.success' >/dev/null || die "не удалось создать метку keep-me"

    step "модуль 05 обновляет панель"
    run_module05 upgrade
    grep -q "обновляю до" "${LOG_DIR}/upgrade.log" || die "модуль не распознал устаревшую версию"
    local backup
    backup=$(find /root/3xui-node-backups -maxdepth 1 -name 'x-ui-db-*' | sort | tail -n 1)
    [[ -n "$backup" ]] || die "бэкап базы не создан"
    python3 -I -c "import sqlite3, sys; c = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True); \
        sys.exit(0 if ('keep-me',) in c.execute('select tag from inbounds').fetchall() else 1)" "${backup}/x-ui/x-ui.db" \
        || die "в бэкапе нет данных старой панели"
    echo "  ok   бэкап ${backup} содержит данные старой панели"
    panel_api "$(state_get XUI_API_TOKEN)" /panel/api/inbounds/list | jq -e '[.obj[].tag] | index("keep-me")' >/dev/null \
        || die "инбаунд keep-me потерян при обновлении"
    echo "  ok   данные старой панели сохранились"
    bash "${E2E}/check.sh"
}

scenario_no_ip_limit() {
    step "IP Limit выключен, пароль начинается с «-»"
    bash "${E2E}/fixture.sh" false '-Kq7!x#P2&m_Z@9w^R+e=' false
    run_module05 no-ip-limit
    bash "${E2E}/check.sh"
}

scenario_psiphon() {
    step "модуль 05, затем модуль 06 в режиме psiphon"
    bash "${E2E}/fixture.sh" true
    run_module05 psiphon-05
    # shellcheck source=lib/common.sh
    source "${REPO}/lib/common.sh"
    save_var AI_MODE psiphon
    save_var PSIPHON_REGION ""
    save_var PSIPHON_PORT 1080
    save_var PSIPHON_IP_DETECT false
    echo "  ..   $(date -u +%H:%M:%S) модуль 06 (psiphon)"
    if ! bash "${REPO}/install.sh" --only 06_ai_routing >"${LOG_DIR}/psiphon-06.log" 2>&1; then
        tail -n 40 "${LOG_DIR}/psiphon-06.log" >&2
        die "модуль 06 завершился с ошибкой"
    fi
    echo "  ..   $(date -u +%H:%M:%S) модуль 06 завершён"
    sed 's/\x1b\[[0-9;]*m//g' "${LOG_DIR}/psiphon-06.log" | grep -aE '\[(OK|WARN|INFO)\]' | cut -c1-160 || true

    local pinned running
    pinned=$(sed -n 's/^PSIPHON_IMAGE="\(.*\)"$/\1/p' "${REPO}/modules/06_ai_routing.sh")
    running=$(docker inspect --format '{{.Config.Image}}' vps-psiphon 2>/dev/null || true)
    [[ -n "$pinned" && "$running" == "$pinned" ]] || die "контейнер запущен из «${running}», а закреплён «${pinned}»"
    echo "  ok   контейнер запущен из закреплённого образа ${pinned}"
    [[ "$(state_get PSIPHON_STATUS)" == ok ]] || die "PSIPHON_STATUS=$(state_get PSIPHON_STATUS), ожидался ok"
    systemctl is-active --quiet vps-psiphon || die "служба vps-psiphon не активна"
    local direct_ip tunnel_ip
    direct_ip=$(curl -4 -fsS --max-time 15 https://api.ipify.org || true)
    tunnel_ip=$(curl -4 -fsS --max-time 20 --socks5-hostname 127.0.0.1:1080 https://api.ipify.org || true)
    [[ -n "$tunnel_ip" && "$tunnel_ip" != "$direct_ip" ]] || die "туннель не выводит трафик (напрямую ${direct_ip:-?}, через Psiphon ${tunnel_ip:-нет})"
    echo "  ok   туннель Psiphon работает: напрямую ${direct_ip}, через Psiphon ${tunnel_ip}"
    ss -tln | grep -qE '(0\.0\.0\.0|\*|\[::\]):1080\b' && die "SOCKS5 Psiphon опубликован не только на loopback"
    echo "  ok   SOCKS5 Psiphon только на 127.0.0.1"

    local tpl
    tpl=$(panel_api "$(state_get XUI_API_TOKEN)" /panel/api/xray/ -X POST | jq -r '.obj | (fromjson? // .) | .xraySetting | (fromjson? // .)')
    jq -e '.outbounds[] | select(.tag == "psiphon-out") | .settings == {"address": "127.0.0.1", "port": 1080}' <<<"$tpl" >/dev/null \
        || die "в шаблоне нет корректного аутбаунда psiphon-out"
    jq -e '[.routing.rules[] | select(.outboundTag == "psiphon-out" and .network == "tcp")] | length == 1' <<<"$tpl" >/dev/null \
        || die "нет правила Gemini → psiphon-out"
    echo "  ok   аутбаунд psiphon-out и маршрут Gemini в шаблоне Xray"
    bash "${E2E}/check.sh"

    step "режим AI none: модуль 06 снимает маршруты Psiphon"
    save_var AI_MODE none
    bash "${REPO}/install.sh" --only 06_ai_routing >"${LOG_DIR}/psiphon-none.log" 2>&1 \
        || { tail -n 30 "${LOG_DIR}/psiphon-none.log" >&2; die "модуль 06 (none) завершился с ошибкой"; }
    tpl=$(panel_api "$(state_get XUI_API_TOKEN)" /panel/api/xray/ -X POST | jq -r '.obj | (fromjson? // .) | .xraySetting | (fromjson? // .)')
    jq -e '([.outbounds[] | select(.tag == "psiphon-out")] | length == 0)
           and ([.routing.rules[] | select((.domain // []) | index("geosite:google-deepmind"))] | length == 0)' <<<"$tpl" >/dev/null \
        || die "после режима none в шаблоне остались маршруты Psiphon"
    echo "  ok   маршруты Psiphon сняты"
    bash "${E2E}/check.sh"
}

case "${1:-}" in
    fresh)       scenario_fresh ;;
    upgrade)     scenario_upgrade ;;
    no-ip-limit) scenario_no_ip_limit ;;
    psiphon)     scenario_psiphon ;;
    *) echo "Сценарий: fresh | upgrade | no-ip-limit | psiphon" >&2; exit 2 ;;
esac
echo; echo "=== сценарий ${1} пройден"
