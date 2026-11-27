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

is_interactive_tty() {
    [[ "$NON_INTERACTIVE" != "true" ]] && [[ -t 0 || "${INSTALL_INTERACTIVE_TEST:-false}" == "true" ]]
}

acquire_install_lock() {
    command -v flock >/dev/null 2>&1 || return 0
    init_state
    exec 9<>"$INSTALL_LOCK_FILE"
    chmod 600 "$INSTALL_LOCK_FILE" 2>/dev/null || true
    if flock -n 9; then
        : > "$INSTALL_LOCK_FILE"
        printf '%s\n' "$$" >&9
        return 0
    fi

    local active_pid=""
    active_pid=$(tr -dc '0-9' < "$INSTALL_LOCK_FILE" 2>/dev/null || true)
    log_warn "Обнаружен другой активный процесс установки${active_pid:+ (PID ${active_pid})}."
    if [[ -n "$active_pid" ]] && ps -p "$active_pid" >/dev/null 2>&1; then
        ps -p "$active_pid" -o pid,etime,args 2>/dev/null || true
    fi

    if is_interactive_tty; then
        local lock_choice
        while true; do
            echo ""
            echo "  [1] Подождать завершения предыдущего процесса (до 120 с)"
            echo "  [2] Остановить предыдущий процесс (SIGTERM) и продолжить"
            echo "  [0] Выход"
            read -erp "  Выбор [1]: " lock_choice
            case "${lock_choice:-1}" in
                1)
                    log_info "Ожидание завершения предыдущей установки..."
                    flock -w 120 9 || log_err "Предыдущая установка не завершилась за 120 с."
                    break
                    ;;
                2)
                    if [[ -n "$active_pid" ]] && ps -p "$active_pid" >/dev/null 2>&1; then
                        kill -TERM "$active_pid" 2>/dev/null || true
                        sleep 2
                    fi
                    flock -w 15 9 || log_err "Не удалось получить блокировку установки (${INSTALL_LOCK_FILE})."
                    break
                    ;;
                0) exit 0 ;;
                *) echo -e "${YELLOW}Введите 1, 2 или 0.${NC}" ;;
            esac
        done
    else
        log_info "Ожидание освобождения блокировки установки (до 120 с)..."
        flock -w 120 9 || log_err "Другой процесс установки ещё выполняется (${INSTALL_LOCK_FILE})."
    fi
    : > "$INSTALL_LOCK_FILE"
    printf '%s\n' "$$" >&9
}

next_module_after() {
    local done_mod="$1" idx next_idx
    for idx in "${!MODULES[@]}"; do
        if [[ "${MODULES[$idx]}" == "$done_mod" ]]; then
            next_idx=$((idx + 1))
            if (( next_idx < ${#MODULES[@]} )); then
                printf '%s\n' "${MODULES[$next_idx]}"
                return 0
            fi
            return 1
        fi
    done
    return 2
}

acquire_install_lock

if [[ -n "$XUI_VERSION_ARG" ]]; then
    validate_xui_version "$XUI_VERSION_ARG"
    export XUI_VERSION="$XUI_VERSION_ARG"
    init_state
    save_var XUI_VERSION "$XUI_VERSION_ARG"
    log_info "Версия 3x-ui зафиксирована: ${XUI_VERSION_ARG}"
fi

if $RESUME; then
    if [[ -f "$PROGRESS_FILE" ]]; then
        LAST_DONE=$(tr -d '[:space:]' < "$PROGRESS_FILE" || true)
        if NEXT_MOD=$(next_module_after "$LAST_DONE"); then
            FROM_MODULE="$NEXT_MOD"
            repair_interrupted_dpkg
            log_info "Продолжение с модуля: ${FROM_MODULE}"
        elif [[ "$LAST_DONE" == "${MODULES[$(( ${#MODULES[@]} - 1 ))]}" ]]; then
            log_ok "Все модули уже были завершены ранее."
            exit 0
        else
            log_warn "Неизвестный модуль в ${PROGRESS_FILE}: ${LAST_DONE:-пусто} — начинаю сначала."
        fi
    else
        log_info "Сохранённый прогресс не найден — запускаю установку сначала."
    fi
elif [[ -z "$ONLY_MODULE" && -z "$FROM_MODULE" && -z "$CONFIG_FILE" ]] && is_interactive_tty \
    && [[ -f "$PROGRESS_FILE" && -f "$STATE_FILE" ]]; then
    LAST_DONE=$(tr -d '[:space:]' < "$PROGRESS_FILE" || true)
    if NEXT_MOD=$(next_module_after "$LAST_DONE"); then
        CUR_MOD=""
        [[ -f "$CURRENT_MODULE_FILE" ]] && CUR_MOD=$(tr -d '[:space:]' < "$CURRENT_MODULE_FILE" || true)
        SAVED_META=$(bash -c 'source "$1" 2>/dev/null || true; printf "%s|%s|%s" "${DOMAIN:-}" "${SERVER_IP:-}" "${SSH_PORT:-}"' _ "$STATE_FILE")
        IFS='|' read -r SAVED_DOMAIN SAVED_IP SAVED_SSH <<<"$SAVED_META"

        echo ""
        log_warn "Обнаружена незавершённая предыдущая установка!"
        [[ -n "$SAVED_DOMAIN" || -n "$SAVED_IP" ]] && echo "  Узел:               ${SAVED_DOMAIN:-?} (${SAVED_IP:-?}, SSH:${SAVED_SSH:-?})"
        echo "  Последний успешный: ${LAST_DONE}"
        [[ -n "$CUR_MOD" ]] && echo "  Прервана на:        ${CUR_MOD}"
        echo "  Следующий шаг:      ${NEXT_MOD}"
        echo ""
        echo "  [1] Продолжить с модуля ${NEXT_MOD} (рекомендуется)"
        echo "  [2] Перезапустить установку сначала (с ${MODULES[0]})"
        echo "  [0] Выход"
        while true; do
            read -erp "  Выбор [1]: " RESUME_CHOICE
            case "${RESUME_CHOICE:-1}" in
                1)
                    FROM_MODULE="$NEXT_MOD"
                    repair_interrupted_dpkg
                    log_info "Продолжение установки с модуля: ${FROM_MODULE}"
                    break
                    ;;
                2)
                    rm -f "$PROGRESS_FILE" "$CURRENT_MODULE_FILE"
                    repair_interrupted_dpkg
                    log_info "Перезапуск установки сначала."
                    break
                    ;;
                0)
                    exit 0
                    ;;
                *)
                    echo -e "${YELLOW}Введите 1, 2 или 0.${NC}"
                    ;;
            esac
        done
    fi
fi

run_module() {
    local mod="$1"
    local script="${BASE_DIR}/modules/${mod}.sh"
    [[ -f "$script" ]] || log_err "Модуль не найден: ${mod}"
    print_banner "Модуль: ${mod}"
    export BASE_DIR NON_INTERACTIVE
    if [[ -z "$ONLY_MODULE" ]]; then
        init_state
        printf '%s\n' "$mod" > "$CURRENT_MODULE_FILE"
        chmod 600 "$CURRENT_MODULE_FILE"
    fi
    bash "$script" "$BASE_DIR"
    if [[ -z "$ONLY_MODULE" ]]; then
        init_state
        printf '%s\n' "$mod" > "$PROGRESS_FILE"
        chmod 600 "$PROGRESS_FILE"
    fi
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

rm -f "$CURRENT_MODULE_FILE"
log_ok "Все этапы установки успешно завершены."
