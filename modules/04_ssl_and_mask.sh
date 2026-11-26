#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

mkdir -p "/etc/nginx/ssl/${DOMAIN}" /var/www/html /var/www/masksite \
         /var/www/geo /var/cache/nginx/html_cache /etc/nginx/conf.d/node-ext \
         /etc/nginx/conf.d/masksite-api

log_info "Подготовка ACME webroot для ${DOMAIN}..."
cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
events { worker_connections 1024; }
http {
    server {
        listen 80;
        listen [::]:80;
        server_name ${DOMAIN};
        location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
        location / { return 444; }
    }
}
EOF
systemctl enable --now nginx >/dev/null 2>&1
systemctl restart nginx

mkdir -p /var/www/html/.well-known/acme-challenge
PROBE_TOKEN=$(openssl rand -hex 8)
echo "$PROBE_TOKEN" > "/var/www/html/.well-known/acme-challenge/${PROBE_TOKEN}"
if ! curl -4fsSL --max-time 6 --resolve "${DOMAIN}:80:127.0.0.1" \
    "http://${DOMAIN}/.well-known/acme-challenge/${PROBE_TOKEN}" | grep -q "$PROBE_TOKEN"; then
    log_warn "Локальная проверка ACME webroot не прошла — проверьте порт 80."
fi
rm -f "/var/www/html/.well-known/acme-challenge/${PROBE_TOKEN}"

if [[ ! -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]]; then
    log_info "Выпуск ECDSA-сертификата Let's Encrypt для ${DOMAIN}..."
    certbot certonly --webroot -w /var/www/html --non-interactive --agree-tos \
        --email "${LE_EMAIL}" -d "${DOMAIN}" --key-type ecdsa
else
    log_ok "Сертификат для ${DOMAIN} уже существует, переводим на webroot-продление."
    certbot reconfigure --cert-name "${DOMAIN}" --authenticator webroot --webroot-path /var/www/html --non-interactive >/dev/null 2>&1 || true
fi

ln -sf "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" "/etc/nginx/ssl/${DOMAIN}/fullchain.pem"
ln -sf "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"   "/etc/nginx/ssl/${DOMAIN}/privkey.pem"

mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat <<'EOF' > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
#!/bin/bash
systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

MASK_API_CONF="/etc/nginx/conf.d/masksite-api/site.conf"
rm -rf /var/www/masksite/*
case "${MASK_TEMPLATE:-cloud-storage}" in
    reverse-proxy)
        log_info "Режим маскировки: Reverse Proxy -> ${REVERSE_PROXY_URL}"
        python3 "${BASE_DIR}/lib/mask_site.py" cleanup-api-conf --nginx-api-conf="${MASK_API_CONF}"
        ;;
    *)
        log_info "Развёртывание многостраничного портала ${MASK_TEMPLATE:-cloud-storage}..."
        MASK_META=$(python3 "${BASE_DIR}/lib/mask_site.py" deploy \
            --templates-dir="${BASE_DIR}/templates/sites" \
            --template="${MASK_TEMPLATE:-cloud-storage}" \
            --domain="${DOMAIN}" \
            --output-dir=/var/www/masksite \
            --nginx-api-conf="${MASK_API_CONF}" \
            --mask-seed="${MASK_SEED:-}")
        MASK_TEMPLATE=$(jq -r '.template' <<<"$MASK_META")
        BRAND_NAME=$(jq -r '.brand_name' <<<"$MASK_META")
        MASK_SEED=$(jq -r '.mask_seed' <<<"$MASK_META")
        NODE_REGION=$(jq -r '.node_region' <<<"$MASK_META")
        APP_VER=$(jq -r '.app_ver' <<<"$MASK_META")
        save_var MASK_TEMPLATE "$MASK_TEMPLATE"
        save_var BRAND_NAME "$BRAND_NAME"
        save_var MASK_SEED "$MASK_SEED"
        save_var NODE_REGION "$NODE_REGION"
        save_var APP_VER "$APP_VER"
        log_ok "Портал ${MASK_TEMPLATE} (${BRAND_NAME}, тема: $(jq -r '.theme' <<<"$MASK_META")) развёрнут."
        ;;
esac

cat <<'EOF' > /var/www/html/404.html
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>404 Not Found</title>
<style>body{font-family:system-ui,sans-serif;background:#0f172a;color:#cbd5e1;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}main{text-align:center}h1{font-size:2.4rem;margin:0 0 .5rem;color:#f8fafc}p{color:#94a3b8;margin:0}</style>
</head><body><main><h1>404</h1><p>The requested resource was not found.</p></main></body></html>
EOF

# Зеркало geo-файлов для Happ заполняет модуль 05 из файлов панели (3xui-node-geo-update).
# Прежний скрипт с cron качал их отдельно, без проверки целостности, — убираем его при повторном запуске.
rm -f /usr/local/sbin/update-geo-mirror.sh /etc/cron.d/update-geo-mirror

chown -R www-data:www-data /var/www /var/cache/nginx
log_ok "SSL-сертификат ECDSA и сайт-заглушка (${MASK_TEMPLATE}) готовы."
