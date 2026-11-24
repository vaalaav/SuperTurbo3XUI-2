#!/usr/bin/env bash
set -eu

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${BASE_DIR}/lib/common.sh"
require_root

MODULES=(
    "01_preflight"
    "02_system_tuning"
    "03_security_stack"
    "04_ssl_and_mask"
    "05_install_3xui"
    "06_ai_routing"
    "07_nginx_config"
    "08_cli_and_audit"
)

ONLY_MODULE=""
FROM_MODULE=""
RESUME=false
CONFIG_FILE=""
NON_INTERACTIVE=false
XUI_VERSION_ARG=""

usage() {
    cat <<EOF
Использование: $(basename "$0") [опции]

Опции:
  --only <модуль>    Запустить один конкретный модуль
  --from <модуль>    Запустить начиная с указанного модуля
  --resume           Продолжить с последнего незавершённого модуля
  --config <файл>    Неинтерактивный запуск с готовым state.env
  --xui-version <v> Версия 3x-ui (тег релиза, не ниже v${XUI_MIN_VERSION}; по умолчанию ${XUI_DEFAULT_VERSION})
  --list             Показать список доступных модулей
  -h, --help         Справка
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only)    ONLY_MODULE="${2:-}"; shift 2 ;;
        --from)    FROM_MODULE="${2:-}"; shift 2 ;;
        --resume)  RESUME=true; shift ;;
        --config)  CONFIG_FILE="${2:-}"; NON_INTERACTIVE=true; shift 2 ;;
        --xui-version) XUI_VERSION_ARG="${2:-}"; shift 2 ;;
        --list)    printf '%s\n' "${MODULES[@]}"; exit 0 ;;
        -h|--help) usage; exit 0 ;;
        *)         log_err "Неизвестный аргумент: $1" ;;
    esac
done

if [[ -n "$CONFIG_FILE" ]]; then
    [[ -f "$CONFIG_FILE" ]] || log_err "Файл конфигурации не найден: $CONFIG_FILE"
    init_state
    cp "$CONFIG_FILE" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
    save_var NON_INTERACTIVE "true"
    log_ok "Конфигурация загружена из ${CONFIG_FILE}"
fi

if [[ -n "$XUI_VERSION_ARG" ]]; then
    validate_xui_version "$XUI_VERSION_ARG"
    export XUI_VERSION="$XUI_VERSION_ARG"
    init_state
    save_var XUI_VERSION "$XUI_VERSION_ARG"
    log_info "Версия 3x-ui зафиксирована: ${XUI_VERSION_ARG}"
fi

if $RESUME && [[ -f "$PROGRESS_FILE" ]]; then
    LAST_DONE=$(cat "$PROGRESS_FILE")
    for idx in "${!MODULES[@]}"; do
        if [[ "${MODULES[$idx]}" == "$LAST_DONE" ]]; then
            NEXT_IDX=$((idx + 1))
            if (( NEXT_IDX < ${#MODULES[@]} )); then
                FROM_MODULE="${MODULES[$NEXT_IDX]}"
                log_info "Продолжение с модуля: ${FROM_MODULE}"
            else
                log_ok "Все модули уже были завершены ранее."
                exit 0
            fi
            break
        fi
    done
fi

run_module() {
    local mod="$1"
    local script="${BASE_DIR}/modules/${mod}.sh"
    [[ -f "$script" ]] || log_err "Модуль не найден: ${mod}"
    print_banner "Модуль: ${mod}"
    export BASE_DIR NON_INTERACTIVE
    bash "$script" "$BASE_DIR"
    init_state
    echo "$mod" > "$PROGRESS_FILE"
    chmod 600 "$PROGRESS_FILE"
}

if [[ -n "$ONLY_MODULE" ]]; then
    run_module "$ONLY_MODULE"
    exit 0
fi

started=false
[[ -z "$FROM_MODULE" ]] && started=true

for mod in "${MODULES[@]}"; do
    [[ "$mod" == "$FROM_MODULE" ]] && started=true
    if $started; then
        run_module "$mod"
    fi
done

log_ok "Все этапы установки успешно завершены."
