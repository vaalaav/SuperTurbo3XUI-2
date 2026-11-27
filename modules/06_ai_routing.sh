#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

# WARP удалён из проекта. Ноды, установленные с режимом warp или combo, переводятся на none и psiphon;
# маршруты WARP, оставшиеся в шаблоне Xray, снимает configure-ai.
case "${AI_MODE:-none}" in
    warp)
        log_warn "Режим WARP удалён из проекта — AI-модуль переводится в none, маршруты WARP снимаются."
        AI_MODE="none"; save_var AI_MODE none ;;
    combo)
        log_warn "Режим combo (WARP + Psiphon) удалён — остаётся Psiphon, маршруты WARP снимаются."
        AI_MODE="psiphon"; save_var AI_MODE psiphon ;;
esac

if [[ "${AI_MODE:-none}" == "none" ]]; then
    # Если раньше был выбран AI-выход, его маршруты остаются в шаблоне Xray (модуль 05 их переносит):
    # снимаем их, чтобы режим none действительно означал прямой выход.
    ensure_xui_api_token
    python3 "${BASE_DIR}/lib/xui_api.py" configure-ai \
        --panel-port="${PANEL_PORT}" --panel-path="${PANEL_PATH}" \
        --panel-user="${PANEL_USER}" --panel-pass="${PANEL_PASS}" --ai-mode=none >/dev/null
    restart_xui
    save_var PSIPHON_STATUS "off"
    log_info "AI-модуль отключён (AI_MODE=none): маршруты AI-выходов в Xray не используются."
    exit 0
fi

# --- Psiphon: выход для Gemini через установщик Chara-Freedom/vps-psiphon ---------------
# Установщик берётся по закреплённому коммиту и сверяется по sha256; образ контейнера закреплён
# по digest. Обновление — сменить три значения ниже после проверки новой версии.
PSIPHON_INSTALLER_COMMIT="a42966845ecc5b477d14962b9ddf5c284dbc1bcd"   # vps-psiphon 1.3, 2026-11-10
PSIPHON_INSTALLER_SHA256="1428beeaab91de159e5354308a8b30948ca6c406bfa37a5d5298071e0f6319d2"
# Образ собирается из исходников psiphon-tunnel-core (swarupsengupta2007/psiphon-docker); digest на 2026-11-24.
PSIPHON_IMAGE="swarupsengupta2007/psiphon@sha256:ed678abc7145e0fb550eb889a5dfed74bd8495bca16b958d6b7ac582d869bfe6"
PSIPHON_INSTALL_LOG="/var/log/3xui-node-psiphon-install.log"
PSIPHON_OK=false

# Docker из подписанного репозитория дистрибутива, а не скриптом get.docker.com без проверки.
ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_info "Установка Docker (пакет docker.io дистрибутива)..."
        apt_get update -qq
        apt_get install -y -qq docker.io >/dev/null
    fi
    systemctl enable --now docker >/dev/null 2>&1 || true
    docker info >/dev/null 2>&1 || log_err "Docker установлен, но не отвечает — проверьте systemctl status docker."
}

# Туннель считается рабочим, когда запрос через SOCKS5 выходит в интернет не с IP сервера.
# Установщик ждёт туннель 120 с и, если служба жива, завершается успешно и без него.
psiphon_exit_ip() {
    curl -4 -fsS --max-time 15 --socks5-hostname "127.0.0.1:${PSIPHON_PORT}" https://api.ipify.org 2>/dev/null || true
}

setup_psiphon() {
    local tmp exit_ip=""
    ensure_docker
    # Остатки прежней схемы модуля (git-клон и самосборный образ) мешают установщику.
    [[ -d /opt/vps-psiphon/.git ]] && rm -rf /opt/vps-psiphon
    docker image rm -f vps-psiphon:local >/dev/null 2>&1 || true

    tmp=$(mktemp)
    if ! curl -fsSL --retry 3 --max-time 60 -o "$tmp" \
        "https://raw.githubusercontent.com/Chara-Freedom/vps-psiphon/${PSIPHON_INSTALLER_COMMIT}/psiphon_install.sh"; then
        rm -f "$tmp"; log_warn "Не удалось скачать установщик vps-psiphon."; return 1
    fi
    if ! echo "${PSIPHON_INSTALLER_SHA256}  ${tmp}" | sha256sum -c --quiet - >/dev/null 2>&1; then
        rm -f "$tmp"; log_warn "Установщик vps-psiphon не совпал по sha256 — не запускаю."; return 1
    fi

    log_info "Установка Psiphon (vps-psiphon, регион ${PSIPHON_REGION:-авто}, лог: ${PSIPHON_INSTALL_LOG})..."
    ( umask 077; : > "$PSIPHON_INSTALL_LOG" )
    # --bulk-test-mb 0: сторожевой процесс судит о выходе по странице YouTube, без замера скорости
    # докачкой 4 МБ каждые 5 минут (около 35 ГБ трафика в месяц).
    local args=(--socks-port "$PSIPHON_PORT" --bind-loopback --no-http --impersonate --bulk-test-mb 0
                --image "$PSIPHON_IMAGE")
    [[ -n "${PSIPHON_REGION:-}" ]] && args+=(--region "$PSIPHON_REGION")
    if ! bash "$tmp" "${args[@]}" </dev/null >>"$PSIPHON_INSTALL_LOG" 2>&1; then
        rm -f "$tmp"
        tail -n 15 "$PSIPHON_INSTALL_LOG" >&2 || true
        log_warn "Установщик vps-psiphon завершился с ошибкой — подробности в ${PSIPHON_INSTALL_LOG}."
        return 1
    fi
    rm -f "$tmp"

    log_info "Ожидание туннеля Psiphon (до 3 минут)..."
    for _ in $(seq 1 36); do
        exit_ip=$(psiphon_exit_ip)
        [[ -n "$exit_ip" && "$exit_ip" != "$SERVER_IP" ]] && break
        exit_ip=""
        sleep 5
    done
    if [[ -z "$exit_ip" ]]; then
        log_warn "Туннель Psiphon не поднялся за 3 минуты; служба vps-psiphon продолжает попытки."
        return 1
    fi
    log_ok "Туннель Psiphon работает: выход через ${exit_ip} (SOCKS5 127.0.0.1:${PSIPHON_PORT})."
}

PSIPHON_STATUS="off"
if [[ "$AI_MODE" == "psiphon" ]]; then
    if setup_psiphon; then
        PSIPHON_OK=true
        PSIPHON_STATUS="ok"
    else
        PSIPHON_STATUS="failed"
        log_warn "Маршруты Gemini через Psiphon НЕ добавлены, чтобы не отправлять трафик в нерабочий туннель."
        log_warn "Проверка: vps-psiphon (статус) и journalctl -u vps-psiphon; повтор: my3xui run 06_ai_routing."
    fi
fi
save_var PSIPHON_STATUS "$PSIPHON_STATUS"

# В Xray попадает только то, что реально работает: без туннеля маршруты Psiphon не добавляются.
EFFECTIVE_MODE="none"
$PSIPHON_OK && EFFECTIVE_MODE="psiphon"

log_info "Интеграция AI-маршрутов (${EFFECTIVE_MODE}) в 3x-ui..."
ensure_xui_api_token
AI_RES=$(python3 "${BASE_DIR}/lib/xui_api.py" configure-ai \
    --panel-port="${PANEL_PORT}" \
    --panel-path="${PANEL_PATH}" \
    --panel-user="${PANEL_USER}" \
    --panel-pass="${PANEL_PASS}" \
    --ai-mode="${EFFECTIVE_MODE}" \
    --psiphon-port="${PSIPHON_PORT}" \
    --psiphon-ip-detect="${PSIPHON_IP_DETECT}")

restart_xui
APPLIED=$(jq -r '.applied | join(", ")' <<<"$AI_RES")
if [[ -n "$APPLIED" ]]; then
    log_ok "AI-маршрутизация применена: ${APPLIED}."
else
    log_warn "AI-маршрутизация не применена ни для одного выхода (выбран режим ${AI_MODE})."
fi
