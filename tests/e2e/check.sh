#!/usr/bin/env bash
# Проверяет результат модуля 05 по фактическому состоянию панели, а не по выводу модуля.
# Переменные: EXPECT_VERSION (по умолчанию 3.11.0). Код возврата 0 — все проверки прошли.
set -uo pipefail

# shellcheck source=/dev/null
source /etc/3xui-node/state.env
B="http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
pass=0; fail=0
ok()  { echo "  ok   $*"; pass=$((pass + 1)); }
bad() { echo "  FAIL $*"; fail=$((fail + 1)); }
api() { curl -s --max-time 10 -H "Authorization: Bearer ${XUI_API_TOKEN}" "$B$1" "${@:2}"; }

v=$(/usr/local/x-ui/x-ui -v 2>/dev/null)
[[ "$v" == "${EXPECT_VERSION:-3.11.0}" ]] && ok "версия $v" || bad "версия '$v', ожидалась ${EXPECT_VERSION:-3.11.0}"
ss -tln | grep -q "127.0.0.1:${PANEL_PORT}\b" && ok "панель слушает 127.0.0.1:${PANEL_PORT}" || bad "панель не на 127.0.0.1:${PANEL_PORT}"
if ss -tln | grep -qE "(0\.0\.0\.0|\*|\[::\]):${PANEL_PORT}\b"; then bad "панель слушает публичный интерфейс"; else ok "публичного слушателя панели нет"; fi
cert=$(/usr/local/x-ui/x-ui setting -getCert true 2>/dev/null | awk -F': *' '/^(cert|key):/ {printf "%s", $2}')
[[ -z "$cert" ]] && ok "сертификат панели не задан (TLS у nginx)" || bad "у панели задан сертификат: $cert"

# Вход именно логином и паролем из state.env: проверяет передачу пароля со спецсимволами установщику.
cj=$(mktemp)
csrf=$(curl -s -c "$cj" -b "$cj" "$B/csrf-token" | jq -r .obj)
login=$(curl -s -c "$cj" -b "$cj" -H 'Content-Type: application/json' -H "X-CSRF-Token: $csrf" \
    --data "$(jq -nc --arg u "$PANEL_USER" --arg p "$PANEL_PASS" '{username:$u,password:$p}')" "$B/login" | jq -r .success)
rm -f "$cj"
[[ "$login" == "true" ]] && ok "вход логином и паролем из state.env" || bad "вход логином и паролем не прошёл ($login)"

[[ -n "${XUI_API_TOKEN:-}" ]] && ok "XUI_API_TOKEN сохранён в state.env" || bad "нет XUI_API_TOKEN в state.env"
code=$(api /panel/api/server/status -o /dev/null -w '%{http_code}')
[[ "$code" == 200 ]] && ok "сохранённый токен принимается" || bad "сохранённый токен: HTTP $code"
tokens=$(api /panel/api/setting/apiTokens)
echo "  ..   токены панели: $(jq -r '[.obj[].name] | sort | join(",")' <<<"$tokens")"
[[ "$(jq '[.obj[] | select(.name == "3xui-node")] | length' <<<"$tokens")" == 1 ]] && ok "ровно один токен 3xui-node" || bad "токенов 3xui-node не один"
jq -e '[.obj[] | select(.name == "cli-fallback")] | length == 0' <<<"$tokens" >/dev/null \
    && ok "токен cli-fallback не создавался" || bad "есть токен cli-fallback (перевыпуск без имени)"

links=$(api /panel/api/clients/links/user1 | jq -r '.obj[]?')
grep -q "^vless://${CLIENT_UUID}@${DOMAIN}:443?.*security=reality" <<<"$links" \
    && ok "ссылка Reality на ${DOMAIN}:443 с нашим UUID" || bad "нет корректной ссылки Reality"
grep -q "^vless://${CLIENT_UUID}@${DOMAIN}:443?.*security=tls.*type=xhttp" <<<"$links" \
    && ok "ссылка XHTTP на ${DOMAIN}:443 через TLS" || bad "нет корректной ссылки XHTTP"
[[ "$(api /panel/api/server/status | jq -r .obj.xray.state)" == running ]] && ok "Xray запущен" || bad "Xray не запущен"

# Этап 3: шаблон Xray построен поверх встроенного шаблона панели, а не собран с нуля.
tpl=$(api /panel/api/xray/ -X POST | jq -r '.obj | (fromjson? // .) | .xraySetting | (fromjson? // .)')
jq -e '.api.services | index("RoutingService")' <<<"$tpl" >/dev/null \
    && ok "шаблон Xray содержит RoutingService встроенного шаблона" || bad "в шаблоне Xray нет RoutingService"
jq -e '.metrics.tag == "metrics_out"' <<<"$tpl" >/dev/null && ok "шаблон Xray содержит metrics" || bad "в шаблоне Xray нет metrics"
jq -e '[.outbounds[] | select(.protocol == "freedom" and (.settings.domainStrategy // null) != null)] | length == 0' <<<"$tpl" >/dev/null \
    && ok "нет устаревшего freedom.domainStrategy" || bad "в шаблоне остался freedom.domainStrategy"
issues=$(api /panel/api/xray/geodata/validate -X POST --data-urlencode kind=domain \
    --data-urlencode "tokens=$(jq -r '[.routing.rules[].domain // [] | .[] | select(startswith("geosite:") or startswith("ext:"))] | unique | join(",")' <<<"$tpl")" \
    | jq '.obj | length')
[[ "$issues" == 0 ]] && ok "все geo-категории правил найдены в файлах" || bad "geo-категорий не найдено: $issues"

systemctl is-enabled --quiet 3xui-node-geo-update.timer && ok "таймер обновления geo-файлов включён" || bad "таймер geo-файлов не включён"
if [[ "${ENABLE_GEO_MIRROR:-false}" == "true" ]]; then
    if cmp -s /usr/local/x-ui/bin/geosite_RU.dat /var/www/geo/geosite.dat && cmp -s /usr/local/x-ui/bin/geoip_RU.dat /var/www/geo/geoip.dat; then
        ok "зеркало geo-файлов совпадает с файлами панели"
    else
        bad "зеркало geo-файлов не совпадает с файлами панели"
    fi
fi

if [[ "${ENABLE_IP_LIMIT:-true}" == "true" ]]; then
    fail2ban-client status 3x-ipl >/dev/null 2>&1 && ok "jail 3x-ipl активен" || bad "jail 3x-ipl не активен"
    fail2ban-client status nginx-botsearch >/dev/null 2>&1 && ok "jail nginx-botsearch работает рядом с 3x-ipl" || bad "jail nginx-botsearch пропал"
else
    if fail2ban-client status 3x-ipl >/dev/null 2>&1; then bad "jail 3x-ipl есть при выключенном IP Limit"; else ok "jail 3x-ipl не ставился"; fi
fi
if [[ -f /var/log/3xui-node-xui-install.log ]]; then
    [[ "$(stat -c %a /var/log/3xui-node-xui-install.log)" == 600 ]] && ok "лог установщика с правами 600" || bad "права лога установщика не 600"
fi

echo "  итого: ${pass} ok, ${fail} FAIL"
[[ $fail -eq 0 ]]
