#!/usr/bin/env bash
# Модульные тесты lib/common.sh и формы вызова xui_api.py в модулях.
# Запуск: bash tests/unit/test_common.sh  (root не нужен: STATE_DIR подменяется на временный каталог)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=lib/common.sh
source "${REPO}/lib/common.sh"
set +e   # common.sh включает -e; ниже ошибки проверяются явно

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
STATE_DIR="$TMP/state"; STATE_FILE="$STATE_DIR/state.env"; BACKUP_ROOT="$TMP/backups"; LOG_FILE="$TMP/log"

pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
check_not() { local name="$1"; shift; if "$@"; then bad "$name"; else ok "$name"; fi; }

echo "version_ge"
check     "3.11.0 >= 3.11.0"           version_ge 3.11.0 3.11.0
check     "v3.12.1 >= 3.11.0"          version_ge v3.12.1 3.11.0
check     "3.11.10 >= 3.11.9 (не строковое сравнение)" version_ge 3.11.10 3.11.9
check_not "3.10.2 < 3.11.0"            version_ge 3.10.2 3.11.0
check_not "3.9.0 < 3.11.0 (не строковое сравнение)" version_ge 3.9.0 3.11.0
check_not "пустая версия не проходит"  version_ge "" 3.11.0

echo "validate_xui_version (вызывает log_err и выходит)"
v() { ( validate_xui_version "$1" ) >/dev/null 2>&1; }
check     "v3.11.0 принимается"        v v3.11.0
check     "v3.12.0 принимается"        v v3.12.0
for bad_tag in v3.10.2 3.11.0 latest v3.11 "v3.11.0; rm -rf /"; do
    check_not "«${bad_tag}» отклоняется" v "$bad_tag"
done

echo "save_var / load_state: значения со спецсимволами переживают запись и чтение"
pw='-Kq7!x#P2&m_Z@9w^R+e= $(touch '"$TMP"'/pwned) `id`'
save_var PANEL_PASS "$pw"
save_var XUI_API_TOKEN "tok1"
save_var XUI_API_TOKEN "tok2"
unset PANEL_PASS XUI_API_TOKEN
load_state
check     "пароль восстановлен байт в байт" test "$PANEL_PASS" == "$pw"
check_not "подстановки в пароле не исполнялись" test -e "$TMP/pwned"
check     "повторный save_var заменяет значение" test "$XUI_API_TOKEN" == "tok2"
check     "ключ записан один раз" test "$(grep -c '^XUI_API_TOKEN=' "$STATE_FILE")" -eq 1
check     "state.env с правами 600" test "$(stat -c %a "$STATE_FILE")" == 600

echo "вызовы xui_api.py в модулях: только --опция=значение"
# Значение, начинающееся с «-» (ключ Reality, пароль), argparse иначе принимает за новую опцию.
# Проверяются только строки внутри вызова xui_api.py (до первой строки без «\» в конце).
offenders=$(awk '
    /lib\/xui_api\.py/ { inside = 1 }
    inside && /^[[:space:]]+--[a-z0-9-]+ "/ { print FILENAME ":" FNR ": " $0 }
    inside && !/\\$/ { inside = 0 }
' "$REPO"/modules/05_install_3xui.sh "$REPO"/modules/06_ai_routing.sh)
calls=$(grep -c 'lib/xui_api.py' "$REPO"/modules/05_install_3xui.sh "$REPO"/modules/06_ai_routing.sh | awk -F: '{s += $2} END {print s}')
check     "найдены оба вызова xui_api.py (контроль, что проверка что-то смотрит)" test "$calls" -ge 2
check     "нет формы «--опция \"значение\"»" test -z "$offenders"
[[ -z "$offenders" ]] || echo "$offenders"

echo "итого: ${pass} ok, ${fail} FAIL"
[[ $fail -eq 0 ]]
