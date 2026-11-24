#!/usr/bin/env bash
# Диагностика после упавшего сквозного теста: печатает состояние панели в лог задания
# и копирует файлы в каталог $1 (для артефакта). Ошибки отдельных команд не прерывают сбор.
set -uo pipefail
OUT="${1:-/tmp/e2e-logs}"
mkdir -p "$OUT"

section() { echo; echo "----- $*"; }

section "systemctl status x-ui"
systemctl status x-ui --no-pager -l 2>&1 | head -n 30
section "systemctl cat x-ui (unit и drop-in)"
systemctl cat x-ui --no-pager 2>&1 | grep -vE '^\s*#|^\s*$'
section "/etc/default/x-ui"
cat /etc/default/x-ui 2>&1
section "слушающие порты"
ss -tlnp 2>&1 | grep -E 'x-ui|xray|LISTEN' | head -n 30
section "x-ui setting -show"
/usr/local/x-ui/x-ui setting -show true 2>&1 | tail -n 8
section "/etc/x-ui"
ls -la /etc/x-ui 2>&1
section "журнал x-ui (весь, с точным временем)"
journalctl -u x-ui --no-pager -o short-precise 2>&1 | tee "$OUT/journal-x-ui.log" | grep -avE 'GC percent|memory soft limit' | tail -n 120
section "журнал systemd о x-ui (старты, остановки, лимиты)"
journalctl --no-pager -o short-precise _PID=1 2>&1 | grep -a 'x-ui' | tail -n 40
section "лог модулей проекта"
sed 's/\x1b\[[0-9;]*m//g' /var/log/3xui-node-install.log 2>&1 | tail -n 40
section "лог установщика 3x-ui (хвост)"
sed 's/\x1b\[[0-9;]*m//g' /var/log/3xui-node-xui-install.log 2>&1 | tail -n 40

cp -f /var/log/3xui-node-install.log /var/log/3xui-node-xui-install.log "$OUT/" 2>/dev/null
chmod -R a+r "$OUT"
exit 0
