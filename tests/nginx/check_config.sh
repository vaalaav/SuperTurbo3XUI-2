#!/usr/bin/env bash
# Рендерит nginx.conf модуля 07 с тестовыми параметрами и проверяет его установленным nginx (`nginx -t`).
# Пишет самоподписанный сертификат в /etc/nginx/ssl/<домен> — только для одноразовой машины.
# Запуск: sudo E2E_DISPOSABLE=1 bash tests/nginx/check_config.sh
set -euo pipefail

[[ "${E2E_DISPOSABLE:-}" == "1" ]] || { echo "Только для одноразовой машины: задайте E2E_DISPOSABLE=1." >&2; exit 2; }
[[ $EUID -eq 0 ]] || { echo "Нужен root." >&2; exit 2; }
command -v nginx >/dev/null || { echo "nginx не установлен." >&2; exit 2; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
OUT="${WORK}/nginx.conf"

# Модуль 07 до вызова `nginx -t`, без обращения к state.env и без записи в /etc/nginx/nginx.conf.
awk '/^if ! nginx -t/ {exit} {print}' "${REPO}/modules/07_nginx_config.sh" \
    | sed -e 's|^source .*||' -e 's|^require_root||' -e 's|^load_state||' -e 's|^NGINX_BACKUP=.*||' \
          -e "s|> /etc/nginx/nginx.conf|> ${OUT}|" -e 's|^log_info.*||' > "${WORK}/render.sh"
grep -q "> ${OUT}" "${WORK}/render.sh" || { echo "Не найдена запись nginx.conf в модуле 07 — скрипт рендера устарел." >&2; exit 1; }

export DOMAIN=node.example.com PANEL_PATH=3f9a0c1b2d4e5f607182 PANEL_PORT=41234 SUB_PATH=9b8a7c6d5e4f3a2b1c0d9e8f \
       SUB_PORT=48123 XHTTP_PATH=api/v2/a1b2c3d4e5f6 GEO_PATH=assets/geo/abcde12345 SUB_JSON_PATH=jsonsub0001

mkdir -p "/etc/nginx/ssl/${DOMAIN}" /etc/nginx/conf.d/node-ext /etc/nginx/conf.d/masksite-api /var/cache/nginx/html_cache /var/www/geo /var/www/masksite /var/www/html
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 2 -subj "/CN=${DOMAIN}" \
    -keyout "/etc/nginx/ssl/${DOMAIN}/privkey.pem" -out "/etc/nginx/ssl/${DOMAIN}/fullchain.pem" 2>/dev/null

nginx -v
fail=0
for mask in cloud-storage status-hub dev-docs saas-analytics tech-journal reverse-proxy; do
    for geo in true false; do
        rm -f "$OUT" /etc/nginx/conf.d/masksite-api/site.conf
        if [[ "$mask" != "reverse-proxy" ]]; then
            python3 "${REPO}/lib/mask_site.py" deploy --templates-dir="${REPO}/templates/sites" \
                --template="$mask" --domain="${DOMAIN}" --output-dir=/var/www/masksite \
                --nginx-api-conf=/etc/nginx/conf.d/masksite-api/site.conf >/dev/null
        fi
        MASK_TEMPLATE="$mask" REVERSE_PROXY_URL="https://example.org" ENABLE_GEO_MIRROR="$geo" \
            bash -c "set -eu; source '${WORK}/render.sh'"
        # Регрессия этапа 1: значение 2 nginx отклоняет, и модуль 07 откатывал конфигурацию.
        if grep -qE 'proxy_http_version[[:space:]]+2;' "$OUT"; then
            echo "FAIL mask=${mask} geo=${geo}: proxy_http_version 2"; fail=1; continue
        fi
        if grep -qE '^[[:space:]]*etag[[:space:]]+off;' "$OUT"; then
            echo "FAIL mask=${mask} geo=${geo}: etag off не должен отключать ETag портала"; fail=1; continue
        fi
        if grep -qE 'try_files[[:space:]]+\$uri[[:space:]]+\$uri/[[:space:]]+/index\.html;' "$OUT"; then
            echo "FAIL mask=${mask} geo=${geo}: catch-all /index.html ломает 404 портала"; fail=1; continue
        fi
        if nginx -t -c "$OUT" >"${WORK}/t.log" 2>&1; then
            echo "ok   mask=${mask} geo=${geo}: nginx -t"
        else
            echo "FAIL mask=${mask} geo=${geo}: nginx -t"; cat "${WORK}/t.log"; fail=1
        fi
    done
done
exit "$fail"
