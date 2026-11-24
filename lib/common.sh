#!/usr/bin/env bash
set -eu

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

STATE_DIR="/etc/3xui-node"
STATE_FILE="${STATE_DIR}/state.env"
PROGRESS_FILE="${STATE_DIR}/last_module"
BACKUP_ROOT="/root/3xui-node-backups"
LOG_FILE="/var/log/3xui-node-install.log"

# 3x-ui: проект использует REST API версии 3.11 (клиенты, хосты, токены), поэтому ниже неё не работает.
XUI_DEFAULT_VERSION="v3.11.0"
XUI_MIN_VERSION="3.11.0"
XUI_BIN="/usr/local/x-ui/x-ui"
XUI_TOKEN_NAME="3xui-node"

log_info() { echo -e "${CYAN}[INFO]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"   | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${GREEN}[OK]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$LOG_FILE" 2>/dev/null || echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1" >&2; exit 1; }

print_banner() {
    local title="$1"
    echo -e "\n${BOLD}${CYAN}----------------------------------------------------${NC}"
    echo -e "${BOLD}  ${title}${NC}"
    echo -e "${BOLD}${CYAN}----------------------------------------------------${NC}"
}

require_root() {
    [[ $EUID -eq 0 ]] || log_err "Запустите от имени root."
}

init_state() {
    umask 022
    mkdir -p "$STATE_DIR" "$BACKUP_ROOT"
    chmod 700 "$STATE_DIR" "$BACKUP_ROOT"
    touch "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

save_var() {
    local key="$1"
    local val="$2"
    init_state
    grep -v "^${key}=" "$STATE_FILE" > "${STATE_FILE}.tmp" || true
    printf '%s=%q\n' "$key" "$val" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

load_state() {
    [[ -f "$STATE_FILE" ]] || log_err "Файл состояния ${STATE_FILE} не найден. Запустите 01_preflight."
    # shellcheck disable=SC1090
    source "$STATE_FILE"
}

backup_path() {
    local target="$1"
    local tag="${2:-auto}"
    [[ -e "$target" ]] || return 0
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local dst="${BACKUP_ROOT}/${tag}-${ts}"
    mkdir -p "$dst"
    cp -a "$target" "$dst/" 2>/dev/null || true
    echo "$dst"
}

detect_ssh_port() {
    local p=""
    mkdir -p /run/sshd 2>/dev/null || true
    p=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}' || true)
    if [[ -z "$p" ]] && systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
        p=$(systemctl show ssh.socket -p Listen 2>/dev/null | grep -oE ':[0-9]+' | tr -d ':' | head -n 1 || true)
    fi
    if [[ -z "$p" && -n "${SSH_CONNECTION:-}" ]]; then
        p=$(awk '{print $4}' <<< "$SSH_CONNECTION" || true)
    fi
    if [[ -z "$p" ]]; then
        p=$(ss -tlnp 2>/dev/null | awk '/sshd/ {split($4,a,":"); print a[length(a)]; exit}' || true)
    fi
    if [[ -z "$p" && -f /etc/ssh/sshd_config ]]; then
        p=$(grep -E '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null \
            | awk '{print $NF}' | head -n 1 || true)
    fi
    echo "${p:-22}"
}

detect_client_ip() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        awk '{print $1}' <<< "$SSH_CONNECTION"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        awk '{print $1}' <<< "$SSH_CLIENT"
    else
        echo ""
    fi
}

is_port_free() {
    local port="$1"
    ! ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "(:|\\])${port}$"
}

pick_free_port() {
    local low="$1"
    local high="$2"
    local exclude="${3:-0}"
    local candidate
    for _ in $(seq 1 50); do
        candidate=$(shuf -i "${low}-${high}" -n 1)
        if [[ "$candidate" != "$exclude" ]] && is_port_free "$candidate"; then
            echo "$candidate"
            return 0
        fi
    done
    log_err "Не удалось подобрать свободный порт в диапазоне ${low}-${high}."
}

# Истина, если версия $1 >= $2 (формат X.Y.Z, префикс v допускается).
version_ge() {
    local a="${1#v}" b="${2#v}"
    [[ -n "$a" && "$(printf '%s\n%s\n' "$b" "$a" | sort -V | head -n 1)" == "$b" ]]
}

# Версия установленной 3x-ui (например 3.11.0) или пустая строка.
xui_installed_version() {
    [[ -x "$XUI_BIN" ]] || return 0
    "$XUI_BIN" -v 2>/dev/null | head -n 1 | tr -d '[:space:]' | sed 's/^v//'
}

# Тег релиза 3x-ui вида vX.Y.Z не ниже минимально поддерживаемого.
validate_xui_version() {
    local tag="$1"
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || log_err "Версия 3x-ui должна быть тегом релиза вида v3.11.0 (получено: ${tag})."
    version_ge "$tag" "$XUI_MIN_VERSION" || log_err "Нужна 3x-ui не ниже v${XUI_MIN_VERSION} (запрошена ${tag})."
}

# Код ответа панели на запрос с токеном: 200 — токен рабочий, 401 — отклонён, 000 — панель недоступна.
xui_token_http_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
        -H "Authorization: Bearer $1" \
        "http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/panel/api/server/status" 2>/dev/null || true
}

# Постоянный именованный API-токен проекта: хранится в state.env и переиспользуется.
# Перевыпускается (с тем же именем, без накопления токенов) только если панель его отклонила.
# x-ui setting -getApiToken без имени при каждом вызове аннулирует прежний токен cli-fallback.
ensure_xui_api_token() {
    local code tok
    if [[ -n "${XUI_API_TOKEN:-}" ]]; then
        code=$(xui_token_http_code "$XUI_API_TOKEN")
        if [[ "$code" == "200" ]]; then
            export XUI_API_TOKEN
            return 0
        fi
        [[ "$code" == "401" ]] || log_err "Панель 3x-ui не отвечает на 127.0.0.1:${PANEL_PORT}/${PANEL_PATH} (HTTP ${code:-000})."
        log_warn "Сохранённый API-токен отклонён панелью — выпускаю новый."
    fi
    tok=$("$XUI_BIN" setting -getApiToken -tokenName "$XUI_TOKEN_NAME" 2>/dev/null | awk '/^apiToken:/ {print $2; exit}')
    [[ -n "$tok" ]] || log_err "Не удалось выпустить API-токен 3x-ui (x-ui setting -getApiToken)."
    code=$(xui_token_http_code "$tok")
    [[ "$code" == "200" ]] || log_err "Панель 3x-ui не принимает новый API-токен (HTTP ${code:-000})."
    save_var XUI_API_TOKEN "$tok"
    export XUI_API_TOKEN="$tok"
}
