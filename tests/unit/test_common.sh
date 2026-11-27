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

echo "my3xui security (CrowdSec enable/disable и выборочное удаление блокировок)"
MOCK_BIN="$TMP/bin"
MOCK_LOG="$TMP/mock.log"
MOCK_STATE="$TMP/mock_cs_active"
mkdir -p "$MOCK_BIN"
echo "active" > "$MOCK_STATE"
: > "$MOCK_LOG"

cat <<EOF > "$MOCK_BIN/systemctl"
#!/usr/bin/env bash
echo "systemctl \$*" >> "$MOCK_LOG"
case "\$1" in
    is-active)
        if [[ "\${2:-}" == "--quiet" ]]; then
            [[ "\$(cat "$MOCK_STATE")" == "active" ]]
            exit \$?
        fi
        cat "$MOCK_STATE"
        ;;
    is-enabled)
        [[ "\$(cat "$MOCK_STATE")" == "active" ]] && echo "enabled" || echo "disabled"
        ;;
    list-unit-files)
        echo "crowdsec.service enabled"
        echo "crowdsec-firewall-bouncer.service enabled"
        ;;
    enable)
        echo "active" > "$MOCK_STATE"
        ;;
    disable)
        echo "inactive" > "$MOCK_STATE"
        ;;
esac
EOF

cat <<EOF > "$MOCK_BIN/cscli"
#!/usr/bin/env bash
echo "cscli \$*" >> "$MOCK_LOG"
if [[ "\$1 \$2 \$3" == "decisions list -o" && "\$4" == "json" ]]; then
    cat <<'JSON'
[{"id":1,"scenario":"crowdsecurity/ssh-bf","decisions":[{"id":42,"value":"185.220.101.5","type":"ban","duration":"3h","scenario":"crowdsecurity/ssh-bf"},{"id":43,"value":"45.155.205.91","type":"ban","duration":"2h","scenario":"crowdsecurity/http-probing"}]},{"id":2,"scenario":"manual","decisions":[{"id":44,"value":"91.240.118.0/24","type":"ban","duration":"1h"}]}]
JSON
elif [[ "\$1 \$2" == "decisions list" ]]; then
    echo "ID 42 185.220.101.5 ban"
elif [[ "\$1 \$2" == "decisions delete" ]]; then
    echo "INFO 1 decision(s) deleted"
fi
EOF

cat <<EOF > "$MOCK_BIN/nft"
#!/usr/bin/env bash
echo "nft \$*" >> "$MOCK_LOG"
exit 0
EOF

cat <<'EOF' > "$MOCK_BIN/ufw"
#!/usr/bin/env bash
echo "Status: active"
EOF

cat <<'EOF' > "$MOCK_BIN/fail2ban-client"
#!/usr/bin/env bash
echo "Currently banned: 0"
EOF

chmod +x "$MOCK_BIN"/*

TEST_CLI="$TMP/my3xui"
sed -e 's|^\[\[ \$EUID -eq 0 \]\].*|true|' \
    -e "s|^STATE_FILE=.*|STATE_FILE=\"${STATE_FILE}\"|" \
    -e "s|^INSTALL_DIR=.*|INSTALL_DIR=\"${REPO}\"|" \
    "${REPO}/cli/my3xui" > "$TEST_CLI"
chmod +x "$TEST_CLI"

save_var ENABLE_CROWDSEC "true"

run_test_cli() {
    env PATH="$MOCK_BIN:$PATH" STATE_DIR="$STATE_DIR" STATE_FILE="$STATE_FILE" \
        BACKUP_ROOT="$BACKUP_ROOT" LOG_FILE="$LOG_FILE" "$TEST_CLI" "$@"
}

sec_on=$(run_test_cli security)
check "security показывает ВКЛЮЧЁН при активном CrowdSec" grep -q "ВКЛЮЧЁН" <<<"$sec_on"

run_test_cli security crowdsec disable >/dev/null
unset ENABLE_CROWDSEC; load_state
check "disable останавливает crowdsec и обновляет state.env" test "$ENABLE_CROWDSEC" == "false"
check "disable останавливает bouncer" grep -q "systemctl disable --now crowdsec-firewall-bouncer" "$MOCK_LOG"
check "disable чистит таблицу nft ip crowdsec" grep -q "nft delete table ip crowdsec" "$MOCK_LOG"

sec_off=$(run_test_cli security)
check "security показывает ОТКЛЮЧЁН после disable" grep -q "ОТКЛЮЧЁН" <<<"$sec_off"
check_not "unban при выключенном CrowdSec завершается ошибкой" run_test_cli security crowdsec unban >/dev/null 2>&1

run_test_cli security crowdsec enable >/dev/null
unset ENABLE_CROWDSEC; load_state
check "enable включает crowdsec и обновляет state.env" test "$ENABLE_CROWDSEC" == "true"

: > "$MOCK_LOG"
run_test_cli security crowdsec unban <<<"1,3" >/dev/null
check "интерактивный unban 1,3 удаляет ID 42" grep -q "cscli decisions delete --id 42" "$MOCK_LOG"
check "интерактивный unban 1,3 удаляет ID 44" grep -q "cscli decisions delete --id 44" "$MOCK_LOG"
check_not "интерактивный unban 1,3 не удаляет ID 43" grep -q "cscli decisions delete --id 43" "$MOCK_LOG"

: > "$MOCK_LOG"
run_test_cli security crowdsec unban 43 1.2.3.4 10.0.0.0/24 >/dev/null
check "CLI unban по ID" grep -q "cscli decisions delete --id 43" "$MOCK_LOG"
check "CLI unban по IP" grep -q "cscli decisions delete --ip 1.2.3.4" "$MOCK_LOG"
check "CLI unban по CIDR" grep -q "cscli decisions delete --range 10.0.0.0/24" "$MOCK_LOG"

echo "wait_port_ready (ожидание открытия локального TCP-порта)"
SS_CALLS="$TMP/ss_calls"
: > "$SS_CALLS"
cat <<EOF > "$MOCK_BIN/ss"
#!/usr/bin/env bash
echo x >> "$SS_CALLS"
n=\$(wc -l < "$SS_CALLS")
if (( n >= 2 )); then
    echo "LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*"
fi
EOF
chmod +x "$MOCK_BIN/ss"
check "wait_port_ready дожидается открытия порта 443" \
    env PATH="$MOCK_BIN:$PATH" bash -c 'source "$1/lib/common.sh"; wait_port_ready 443 3 "Xray"' _ "$REPO"
: > "$SS_CALLS"
cat <<'EOF' > "$MOCK_BIN/ss"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/ss"
check_not "wait_port_ready падает по таймауту, если порт не открылся" \
    bash -c 'PATH="'"$MOCK_BIN"':$PATH"; source "$1/lib/common.sh"; wait_port_ready 443 1 "Xray" 2>/dev/null' _ "$REPO"

echo "my3xui ssh change-port (Fail2Ban jail.local и sshd_config.d)"
SSH_TMP="$TMP/ssh_test"
mkdir -p "$SSH_TMP/etc_ssh/sshd_config.d" "$SSH_TMP/bak_root"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' > "$SSH_TMP/etc_ssh/sshd_config"
printf 'Port 22\n' > "$SSH_TMP/etc_ssh/sshd_config.d/50-cloud-init.conf"
printf 'Port 22\n' > "$SSH_TMP/etc_ssh/sshd_config.d/00-custom-ssh.conf"
cat <<'EOF' > "$SSH_TMP/jail.local"
[DEFAULT]
banaction = nftables-multiport

[sshd]
enabled = true
port = 22

[nginx-botsearch]
enabled = true
port = http,https
EOF
cat <<'EOF' > "$MOCK_BIN/sshd"
#!/usr/bin/env bash
exit 0
EOF
cat <<'EOF' > "$MOCK_BIN/systemd-run"
#!/usr/bin/env bash
exit 0
EOF
cat <<'EOF' > "$MOCK_BIN/ss"
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$MOCK_BIN/sshd" "$MOCK_BIN/systemd-run" "$MOCK_BIN/ss"
SSH_CLI="$TMP/my3xui_ssh"
sed -e "s|/etc/ssh/sshd_config\.d/|${SSH_TMP}/etc_ssh/sshd_config.d/|g" \
    -e "s|/etc/ssh/sshd_config|${SSH_TMP}/etc_ssh/sshd_config|g" \
    -e "s|/etc/ssh|${SSH_TMP}/etc_ssh|g" \
    -e "s|/root/ssh-bak-|${SSH_TMP}/bak_root/ssh-bak-|g" \
    -e "s|/etc/fail2ban/jail\.local|${SSH_TMP}/jail.local|g" \
    -e "s|/usr/local/sbin/update-antiscan.py|true|g" \
    "$TEST_CLI" > "$SSH_CLI"
chmod +x "$SSH_CLI"
save_var SSH_PORT "22"
printf '22222\ny\n' | env PATH="$MOCK_BIN:$PATH" STATE_DIR="$STATE_DIR" STATE_FILE="$STATE_FILE" \
    BACKUP_ROOT="$BACKUP_ROOT" LOG_FILE="$LOG_FILE" "$SSH_CLI" ssh change-port >/dev/null
check "change-port комментирует Port в 50-cloud-init.conf" grep -q '^#Port 22' "$SSH_TMP/etc_ssh/sshd_config.d/50-cloud-init.conf"
check "change-port обновляет Port в 00-custom-ssh.conf" grep -qx 'Port 22222' "$SSH_TMP/etc_ssh/sshd_config.d/00-custom-ssh.conf"
check "change-port обновляет port в [sshd]" \
    awk '/^\[sshd\]/{f=1} /^\[/&&!/^\[sshd\]/{f=0} f&&/^port = 22222$/{ok=1} END{exit !ok}' "$SSH_TMP/jail.local"
check "change-port сохраняет port = http,https в [nginx-botsearch]" \
    awk '/^\[nginx-botsearch\]/{f=1} /^\[/&&!/^\[nginx-botsearch\]/{f=0} f&&/^port = http,https$/{ok=1} END{exit !ok}' "$SSH_TMP/jail.local"

echo "backup_path ротация и my3xui backup"
ROT_SRC="$TMP/rot_src"
mkdir -p "$ROT_SRC"
echo "data" > "$ROT_SRC/file.txt"
for i in 1 2 3 4 5 6 7; do
    mkdir -p "${BACKUP_ROOT}/rot-20260101-00000${i}"
done
backup_path "$ROT_SRC" "rot" 5 >/dev/null
rot_count=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name 'rot-*' | wc -l)
check "backup_path оставляет ровно 5 последних копий по тегу" test "$rot_count" -eq 5

BK_TMP="$TMP/bk_test"
mkdir -p "$BK_TMP/etc_xui" "$BK_TMP/bak"
python3 -c 'import sqlite3, sys; c = sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE t(x INT)"); c.commit(); c.close()' "$BK_TMP/etc_xui/x-ui.db"
echo "ssh-ed25519 AAAA test@host" > "$BK_TMP/auth_keys"
BK_CLI="$TMP/my3xui_bk"
sed -e "s|/etc/x-ui|${BK_TMP}/etc_xui|g" \
    -e "s|/root/.ssh/authorized_keys|${BK_TMP}/auth_keys|g" \
    -e "s|/etc/ssh/sshd_config\.d|${BK_TMP}/none_sshd|g" \
    -e "s|/etc/3xui-antiscan-allow\.txt|${BK_TMP}/none_allow|g" \
    -e "s|/etc/letsencrypt|${BK_TMP}/none_le|g" \
    -e "s|/root/vps-credentials\.txt|${BK_TMP}/none_creds|g" \
    "$TEST_CLI" > "$BK_CLI"
chmod +x "$BK_CLI"
BK_OUT="$BK_TMP/bak/node.tar.gz"
env PATH="$MOCK_BIN:$PATH" STATE_DIR="$STATE_DIR" STATE_FILE="$STATE_FILE" \
    BACKUP_ROOT="$BACKUP_ROOT" LOG_FILE="$LOG_FILE" "$BK_CLI" backup "$BK_OUT" >/dev/null
check "my3xui backup создаёт архив" test -s "$BK_OUT"
check "архив backup имеет права 600" test "$(stat -c %a "$BK_OUT")" == 600
check "архив содержит state.env и x-ui.db" \
    bash -c 'tar -tzf "$1" | grep -q "state\.env" && tar -tzf "$1" | grep -q "x-ui\.db"' _ "$BK_OUT"

echo "apt_get (ожидание блокировки dpkg)"
cat <<EOF > "$MOCK_BIN/apt-get"
#!/usr/bin/env bash
printf '%s|%s\n' "\${DEBIAN_FRONTEND:-}" "\$*" >> "$MOCK_LOG"
EOF
chmod +x "$MOCK_BIN/apt-get"
: > "$MOCK_LOG"
env PATH="$MOCK_BIN:$PATH" bash -c 'source "$1/lib/common.sh"; apt_get install -y -qq curl' _ "$REPO"
check "apt_get задаёт DEBIAN_FRONTEND=noninteractive" grep -q '^noninteractive|' "$MOCK_LOG"
check "apt_get передаёт -o DPkg::Lock::Timeout=120" grep -q -- '-o DPkg::Lock::Timeout=120 install -y -qq curl' "$MOCK_LOG"

echo "install.sh: определение незавершённой установки (продолжение / перезапуск)"
INST_TMP="$TMP/inst_test"
mkdir -p "$INST_TMP/lib" "$INST_TMP/modules" "$INST_TMP/state" "$INST_TMP/backups"
cp "${REPO}/lib/common.sh" "$INST_TMP/lib/common.sh"
sed 's/^require_root$/true/' "${REPO}/install.sh" > "$INST_TMP/install.sh"
chmod +x "$INST_TMP/install.sh"
INST_TRACE="$INST_TMP/trace.log"
for m in 01_preflight 02_system_tuning 03_security_stack 04_ssl_and_mask 05_install_3xui 06_ai_routing 07_nginx_config 08_cli_and_audit; do
    cat <<EOF > "$INST_TMP/modules/${m}.sh"
#!/usr/bin/env bash
echo "$m" >> "\${INST_TRACE}"
EOF
    chmod +x "$INST_TMP/modules/${m}.sh"
done

INST_STATE_DIR="$INST_TMP/state"
INST_STATE_FILE="$INST_STATE_DIR/state.env"
INST_PROGRESS_FILE="$INST_STATE_DIR/last_module"
INST_CURRENT_FILE="$INST_STATE_DIR/current_module"
INST_LOCK_FILE="$INST_STATE_DIR/install.lock"
cat <<'EOF' > "$INST_STATE_FILE"
DOMAIN=test.example.com
SERVER_IP=203.0.113.10
SSH_PORT=37971
EOF
chmod 600 "$INST_STATE_FILE"

echo "02_system_tuning" > "$INST_PROGRESS_FILE"
echo "03_security_stack" > "$INST_CURRENT_FILE"
: > "$INST_TRACE"
printf '1\n' | env PATH="$MOCK_BIN:$PATH" STATE_DIR="$INST_STATE_DIR" STATE_FILE="$INST_STATE_FILE" \
    PROGRESS_FILE="$INST_PROGRESS_FILE" CURRENT_MODULE_FILE="$INST_CURRENT_FILE" INSTALL_LOCK_FILE="$INST_LOCK_FILE" \
    BACKUP_ROOT="$INST_TMP/backups" LOG_FILE="$INST_TMP/log" INST_TRACE="$INST_TRACE" \
    INSTALL_INTERACTIVE_TEST="true" bash "$INST_TMP/install.sh" >/dev/null
check "выбор [1] продолжает с 03_security_stack" test "$(head -n 1 "$INST_TRACE")" == "03_security_stack"
check_not "выбор [1] не запускает 01_preflight повторно" grep -qx "01_preflight" "$INST_TRACE"
check "после завершения last_module = 08_cli_and_audit" test "$(cat "$INST_PROGRESS_FILE")" == "08_cli_and_audit"
check_not "после завершения current_module удалён" test -e "$INST_CURRENT_FILE"

echo "02_system_tuning" > "$INST_PROGRESS_FILE"
echo "03_security_stack" > "$INST_CURRENT_FILE"
: > "$INST_TRACE"
printf '2\n' | env PATH="$MOCK_BIN:$PATH" STATE_DIR="$INST_STATE_DIR" STATE_FILE="$INST_STATE_FILE" \
    PROGRESS_FILE="$INST_PROGRESS_FILE" CURRENT_MODULE_FILE="$INST_CURRENT_FILE" INSTALL_LOCK_FILE="$INST_LOCK_FILE" \
    BACKUP_ROOT="$INST_TMP/backups" LOG_FILE="$INST_TMP/log" INST_TRACE="$INST_TRACE" \
    INSTALL_INTERACTIVE_TEST="true" bash "$INST_TMP/install.sh" >/dev/null
check "выбор [2] перезапускает с 01_preflight" test "$(head -n 1 "$INST_TRACE")" == "01_preflight"
check "перезапуск доходит до 08_cli_and_audit" test "$(tail -n 1 "$INST_TRACE")" == "08_cli_and_audit"

: > "$INST_TRACE"
env PATH="$MOCK_BIN:$PATH" STATE_DIR="$INST_STATE_DIR" STATE_FILE="$INST_STATE_FILE" \
    PROGRESS_FILE="$INST_PROGRESS_FILE" CURRENT_MODULE_FILE="$INST_CURRENT_FILE" INSTALL_LOCK_FILE="$INST_LOCK_FILE" \
    BACKUP_ROOT="$INST_TMP/backups" LOG_FILE="$INST_TMP/log" INST_TRACE="$INST_TRACE" \
    bash "$INST_TMP/install.sh" --only 02_system_tuning >/dev/null
check "--only не сбрасывает last_module завершённой установки" test "$(cat "$INST_PROGRESS_FILE")" == "08_cli_and_audit"

echo "итого: ${pass} ok, ${fail} FAIL"
[[ $fail -eq 0 ]]
