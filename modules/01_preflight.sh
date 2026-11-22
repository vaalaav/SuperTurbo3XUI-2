#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root

if [[ "${NON_INTERACTIVE:-false}" == "true" && -f "$STATE_FILE" ]]; then
    load_state
    log_ok "Неинтерактивный режим: параметры загружены из ${STATE_FILE}"
    exit 0
fi

# 1. Проверка ОС
if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ ! "$ID" =~ ^(ubuntu|debian)$ ]] || [[ ! "$VERSION_ID" =~ ^(24\.04|26\.04|12|13)$ ]]; then
        log_warn "ОС: ${PRETTY_NAME:-Unknown}. Поддерживаются Ubuntu 24.04/26.04 и Debian 12/13."
        read -erp "Продолжить всё равно? [y/N]: " cont
        [[ "$cont" =~ ^[Yy]$ ]] || exit 1
    else
        log_ok "ОС: ${PRETTY_NAME}"
    fi
fi

# 2. Базовые инструменты для проверок
command -v curl    >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl; }
command -v python3 >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq python3; }
command -v openssl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq openssl; }

# 3. Определение внешнего IPv4, RAM и текущего SSH
SERVER_IP=$(curl -4fsSL --max-time 6 https://api.ipify.org || curl -4fsSL --max-time 6 https://ifconfig.me/ip || true)
[[ -n "$SERVER_IP" ]] || log_err "Не удалось определить публичный IPv4 сервера."
TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
CUR_SSH_PORT=$(detect_ssh_port)
ADMIN_IP=$(detect_client_ip)

log_info "IPv4: ${SERVER_IP} | RAM: ${TOTAL_RAM_MB} MB | SSH: ${CUR_SSH_PORT}"

# 4. Домен + DoH проверка A / AAAA
while true; do
    read -erp "1. Домен VPS (A-запись -> ${SERVER_IP}): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | LC_ALL=C tr -cd "a-zA-Z0-9.-" | tr "A-Z" "a-z")
    [[ -n "$DOMAIN" && "$DOMAIN" == *.* ]] || { echo -e "${RED}Некорректный домен.${NC}"; continue; }

    DNS_A=$(curl -fsSL --max-time 8 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=${DOMAIN}&type=A" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(a['data'] for a in d.get('Answer',[]) if a.get('type')==1))" 2>/dev/null || true)

    DNS_AAAA=$(curl -fsSL --max-time 8 -H 'accept: application/dns-json' \
        "https://cloudflare-dns.com/dns-query?name=${DOMAIN}&type=AAAA" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(','.join(a['data'] for a in d.get('Answer',[]) if a.get('type')==28))" 2>/dev/null || true)

    [[ -n "$DNS_AAAA" ]] && log_warn "Найдена AAAA-запись (${DNS_AAAA}). Рекомендуется оставить только A-запись."

    if [[ "$DNS_A" == "$SERVER_IP" ]]; then
        log_ok "DoH DNS подтверждён: ${DOMAIN} -> ${SERVER_IP}"
        break
    else
        log_warn "A-запись: ${DNS_A:-пусто}, ожидается: ${SERVER_IP}"
        read -erp "   Продолжить всё равно? [y/N]: " dns_ok
        [[ "$dns_ok" =~ ^[Yy]$ ]] && break
    fi
done

read -erp "2. Email для Let's Encrypt [admin@${DOMAIN}]: " LE_EMAIL
LE_EMAIL=${LE_EMAIL:-"admin@${DOMAIN}"}

# 5. Настройка SSH под два устройства Termius
echo -e "\n3. Порт SSH (текущий: ${CUR_SSH_PORT}):"
echo "   [1] Оставить текущий (${CUR_SSH_PORT})"
echo "   [2] Ввести свой порт вручную (удобно для Termius)"
echo "   [3] Случайный порт (10000-39999)"
read -erp "   Выбор [1]: " SSH_MODE
SSH_PORT="$CUR_SSH_PORT"
SSH_PORT_CHANGED="false"

case "${SSH_MODE:-1}" in
    2)
        while true; do
            read -erp "   Новый порт SSH (1024-39999): " CUSTOM_SSH
            if [[ "$CUSTOM_SSH" =~ ^[0-9]+$ ]] && (( CUSTOM_SSH >= 1024 && CUSTOM_SSH <= 39999 )) && is_port_free "$CUSTOM_SSH"; then
                SSH_PORT="$CUSTOM_SSH"
                [[ "$SSH_PORT" != "$CUR_SSH_PORT" ]] && SSH_PORT_CHANGED="true"
                break
            fi
            echo -e "${RED}Порт некорректен или уже занят.${NC}"
        done
        ;;
    3)
        SSH_PORT=$(pick_free_port 10000 39999 "$CUR_SSH_PORT")
        SSH_PORT_CHANGED="true"
        log_info "Сгенерирован порт SSH: ${SSH_PORT}"
        ;;
esac

# Публичные SSH-ключи (можно вставить с 2 устройств Termius)
SSH_KEYS_FILE="${STATE_DIR}/pending_ssh_keys.pub"
init_state
: > "$SSH_KEYS_FILE"
chmod 600 "$SSH_KEYS_FILE"

echo -e "\n4. SSH-ключи (для 1-2 устройств Termius):"
read -erp "   Добавить публичные SSH-ключи сейчас? [y/N]: " ADD_KEYS
if [[ "${ADD_KEYS:-N}" =~ ^[Yy]$ ]]; then
    echo "   Вставляйте по одному ключу (ssh-ed25519 ...). Пустой Enter — завершить."
    key_idx=1
    while true; do
        read -erp "   Ключ #${key_idx}: " PUBKEY
        [[ -z "$PUBKEY" ]] && break
        if printf '%s\n' "$PUBKEY" | ssh-keygen -lf - >/dev/null 2>&1; then
            printf '%s\n' "$PUBKEY" >> "$SSH_KEYS_FILE"
            log_ok "Ключ #${key_idx} принят."
            key_idx=$((key_idx + 1))
        else
            log_warn "Некорректный формат SSH-ключа, попробуйте снова."
        fi
    done
fi

SSH_LOCK_PASS="false"
if [[ -s "$SSH_KEYS_FILE" || -s /root/.ssh/authorized_keys ]]; then
    echo "   Совет: если 2-е устройство Termius ещё не настроено, выберите N"
    echo "   и закройте пароль позже командой: my3xui ssh lock-password"
    read -erp "   Отключить вход по паролю прямо сейчас? [y/N]: " LOCK_NOW
    [[ "${LOCK_NOW:-N}" =~ ^[Yy]$ ]] && SSH_LOCK_PASS="true"
fi

# 6. Системный DNS (DoT по умолчанию / опциональный DoH)
echo -e "\n5. Системный DNS на VPS:"
echo "   [1] Нативный systemd-resolved DoT (рекомендуется)"
echo "   [2] Не менять системный DNS"
echo "   [3] Локальный DoH (cloudflared 127.0.0.1:5053)"
read -erp "   Выбор [1]: " DNS_CHOICE
case "${DNS_CHOICE:-1}" in
    2) SYSTEM_DNS_MODE="keep" ;;
    3) SYSTEM_DNS_MODE="doh" ;;
    *) SYSTEM_DNS_MODE="dot" ;;
esac

# 7. Шаблон сайта-заглушки
echo -e "\n6. Маскировка домена ${DOMAIN}:"
echo "   [1] Случайный автономный шаблон (рекомендуется)"
echo "   [2] cloud-storage (S3/NVMe облачный портал)"
echo "   [3] status-hub (панель статуса сервисов)"
echo "   [4] dev-docs (портал API-документации)"
echo "   [5] myfakesite (iqubik/myfakesite + Mock API)"
echo "   [6] Reverse Proxy на свой URL"
read -erp "   Выбор [1]: " MASK_CHOICE
REVERSE_PROXY_URL=""
case "${MASK_CHOICE:-1}" in
    2) MASK_TEMPLATE="cloud-storage" ;;
    3) MASK_TEMPLATE="status-hub" ;;
    4) MASK_TEMPLATE="dev-docs" ;;
    5) MASK_TEMPLATE="myfakesite" ;;
    6)
        MASK_TEMPLATE="reverse-proxy"
        read -erp "   URL для Reverse Proxy (https://...): " REVERSE_PROXY_URL
        REVERSE_PROXY_URL=$(echo "$REVERSE_PROXY_URL" | tr -d '[:space:]')
        ;;
    *)
        POOL=("cloud-storage" "status-hub" "dev-docs")
        MASK_TEMPLATE="${POOL[$((RANDOM % ${#POOL[@]}))]}"
        log_info "Выбран случайный шаблон: ${MASK_TEMPLATE}"
        ;;
esac

# 8. uTLS отпечаток Reality
echo -e "\n7. uTLS отпечаток Reality (Xray 26.9.8+ X25519MLKEM768):"
echo "   [1] firefox (рекомендуется)"
echo "   [2] safari"
echo "   [3] chrome"
echo "   [4] randomized"
read -erp "   Выбор [1]: " FP_CHOICE
case "${FP_CHOICE:-1}" in
    2) UTLS_FP="safari" ;;
    3) UTLS_FP="chrome" ;;
    4) UTLS_FP="randomized" ;;
    *) UTLS_FP="firefox" ;;
esac

# 9. Стек безопасности (Antiscan + CrowdSec)
read -erp "8. Включить объединённый nftables-антисканер? [Y/n]: " EN_AS
ENABLE_ANTISCAN=$([[ "${EN_AS:-Y}" =~ ^[Nn]$ ]] && echo "false" || echo "true")

CS_DEF="Y"
(( TOTAL_RAM_MB < 1200 )) && CS_DEF="N"
read -erp "9. Установить CrowdSec + nftables bouncer? (RAM: ${TOTAL_RAM_MB}MB) [${CS_DEF}]: " EN_CS
EN_CS=${EN_CS:-"$CS_DEF"}
ENABLE_CROWDSEC=$([[ "$EN_CS" =~ ^[Yy]$ ]] && echo "true" || echo "false")

# 10. Модуль вывода AI-сервисов (WARP / Psiphon)
echo -e "\n10. Модуль вывода AI-сервисов (ChatGPT/Gemini/Claude):"
echo "    [1] Выключен (трафик через IP VPS)"
echo "    [2] Встроенный Cloudflare WARP (0 МБ лишней RAM)"
echo "    [3] Psiphon в Docker (оптимально для Gemini)"
echo "    [4] Комбинированный (Gemini -> Psiphon, прочее -> WARP)"
read -erp "    Выбор [1]: " AI_CHOICE
PSIPHON_REGION="DE"
PSIPHON_IP_DETECT="false"
case "${AI_CHOICE:-1}" in
    2) AI_MODE="warp" ;;
    3) AI_MODE="psiphon" ;;
    4) AI_MODE="combo" ;;
    *) AI_MODE="none" ;;
esac

if [[ "$AI_MODE" == "psiphon" || "$AI_MODE" == "combo" ]]; then
    read -erp "    Регион Psiphon (DE/NL/GB/US) [DE]: " PSIPHON_REGION
    PSIPHON_REGION=${PSIPHON_REGION:-"DE"}
    read -erp "    Пускать IP-чекеры (ip-geo-detect) через Psiphon? [y/N]: " PIPD
    [[ "${PIPD:-N}" =~ ^[Yy]$ ]] && PSIPHON_IP_DETECT="true"
fi

# 11. Подписка Happ/INCY и зеркало Geo-файлов
read -erp "11. Добавить в подписку Happ/INCY роутинг (RU напрямую)? [Y/n]: " EN_HAPP
ENABLE_HAPP=$([[ "${EN_HAPP:-Y}" =~ ^[Nn]$ ]] && echo "false" || echo "true")

ENABLE_GEO_MIRROR="false"
if [[ "$ENABLE_HAPP" == "true" ]]; then
    read -erp "    Зеркалировать geoip.dat/geosite.dat на Nginx ноды? [Y/n]: " EN_GEO
    ENABLE_GEO_MIRROR=$([[ "${EN_GEO:-Y}" =~ ^[Nn]$ ]] && echo "false" || echo "true")
fi

# 12. Учётные данные панели 3x-ui
RAND_USER=$(python3 -c 'import secrets,string; a=string.ascii_lowercase+string.digits; print("u"+"".join(secrets.choice(a) for _ in range(10)))')
RAND_PASS=$(python3 -c '
import secrets, string
u, l, d, s = string.ascii_uppercase, string.ascii_lowercase, string.digits, "!@#%^&*_-+="
a = u + l + d + s
while True:
    p = "".join(secrets.choice(a) for _ in range(20))
    if any(c in u for c in p) and any(c in l for c in p) and any(c in d for c in p) and any(c in s for c in p):
        print(p); break
')

read -erp "12. Логин панели 3x-ui [${RAND_USER}]: " PANEL_USER
PANEL_USER=${PANEL_USER:-"$RAND_USER"}
read -erp "13. Пароль панели 3x-ui [${RAND_PASS}]: " PANEL_PASS
PANEL_PASS=${PANEL_PASS:-"$RAND_PASS"}

PANEL_PORT=$(pick_free_port 40000 47999 "$SSH_PORT")
SUB_PORT=$(pick_free_port 48000 55999 "$SSH_PORT")
PANEL_PATH=$(openssl rand -hex 10)
SUB_PATH=$(openssl rand -hex 12)
XHTTP_PATH="api/v2/$(openssl rand -hex 6)"
GEO_PATH="assets/geo/$(openssl rand -hex 5)"
CLIENT_UUID=$(python3 -c 'import uuid; print(uuid.uuid4())')
SUB_ID=$(openssl rand -hex 8)

save_var SERVER_IP "$SERVER_IP"
save_var ADMIN_IP "$ADMIN_IP"
save_var DOMAIN "$DOMAIN"
save_var LE_EMAIL "$LE_EMAIL"
save_var CUR_SSH_PORT "$CUR_SSH_PORT"
save_var SSH_PORT "$SSH_PORT"
save_var SSH_PORT_CHANGED "$SSH_PORT_CHANGED"
save_var SSH_LOCK_PASS "$SSH_LOCK_PASS"
save_var SYSTEM_DNS_MODE "$SYSTEM_DNS_MODE"
save_var MASK_TEMPLATE "$MASK_TEMPLATE"
save_var REVERSE_PROXY_URL "$REVERSE_PROXY_URL"
save_var UTLS_FP "$UTLS_FP"
save_var ENABLE_ANTISCAN "$ENABLE_ANTISCAN"
save_var ENABLE_CROWDSEC "$ENABLE_CROWDSEC"
save_var AI_MODE "$AI_MODE"
save_var PSIPHON_REGION "$PSIPHON_REGION"
save_var PSIPHON_IP_DETECT "$PSIPHON_IP_DETECT"
save_var PSIPHON_PORT "1080"
save_var ENABLE_HAPP "$ENABLE_HAPP"
save_var ENABLE_GEO_MIRROR "$ENABLE_GEO_MIRROR"
save_var PANEL_USER "$PANEL_USER"
save_var PANEL_PASS "$PANEL_PASS"
save_var PANEL_PORT "$PANEL_PORT"
save_var SUB_PORT "$SUB_PORT"
save_var PANEL_PATH "$PANEL_PATH"
save_var SUB_PATH "$SUB_PATH"
save_var XHTTP_PATH "$XHTTP_PATH"
save_var GEO_PATH "$GEO_PATH"
save_var CLIENT_UUID "$CLIENT_UUID"
save_var SUB_ID "$SUB_ID"

echo -e "\n${BOLD}Сводка конфигурации:${NC}"
echo "  Домен:       ${DOMAIN} (${SERVER_IP})"
echo "  SSH порт:    ${SSH_PORT} (смена: ${SSH_PORT_CHANGED})"
echo "  DNS ОС:      ${SYSTEM_DNS_MODE}"
echo "  Заглушка:    ${MASK_TEMPLATE}"
echo "  uTLS:        ${UTLS_FP}"
echo "  Antiscan:    ${ENABLE_ANTISCAN} | CrowdSec: ${ENABLE_CROWDSEC}"
echo "  AI-модуль:   ${AI_MODE}"
echo "  Happ Route:  ${ENABLE_HAPP} | Geo-mirror: ${ENABLE_GEO_MIRROR}"
echo ""
read -erp "Начать установку? [Y/n]: " GO
[[ "${GO:-Y}" =~ ^[Nn]$ ]] && exit 0
log_ok "Параметры сохранены в ${STATE_FILE}."
