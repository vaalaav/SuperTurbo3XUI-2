#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

mkdir -p "/etc/nginx/ssl/${DOMAIN}" /var/www/html /var/www/masksite \
         /var/www/geo /var/cache/nginx/html_cache /etc/nginx/conf.d/node-ext

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

PREFIX=$(echo "$DOMAIN" | cut -d. -f1 | sed -E 's/^(.)/\U\1/')
SUFFIXES=("Cloud" "Core" "Grid" "Stack" "Pulse" "Axis" "Mesh" "Vault")
BRAND_NAME="${PREFIX}${SUFFIXES[$((RANDOM % ${#SUFFIXES[@]}))]}"
BUILD_ID=$(openssl rand -hex 4)
REGIONS=("eu-central-1" "eu-north-1" "eu-west-1" "eu-west-3")
NODE_REGION="${REGIONS[$((RANDOM % ${#REGIONS[@]}))]}"
APP_VER="2.$(( (RANDOM % 5) + 1 )).$(( RANDOM % 9 ))"

save_var BRAND_NAME "$BRAND_NAME"
save_var NODE_REGION "$NODE_REGION"
save_var APP_VER "$APP_VER"

rm -rf /var/www/masksite/*
case "${MASK_TEMPLATE:-cloud-storage}" in
    myfakesite)
        log_info "Загрузка и уникализация iqubik/myfakesite (${BRAND_NAME})..."
        BASE_RAW="https://raw.githubusercontent.com/iqubik/myfakesite/main/data"
        curl -fsSL "${BASE_RAW}/index.html" -o /var/www/masksite/index.html
        curl -fsSL "${BASE_RAW}/favicon.ico" -o /var/www/masksite/favicon.ico || true
        sed -i "s/MySphere/${BRAND_NAME}/g; s/YOUDOMEN\.XXX/${DOMAIN}/g" /var/www/masksite/index.html
        sed -i "s|</head>|    <meta name=\"build-id\" content=\"${BUILD_ID}\">\n</head>|" /var/www/masksite/index.html
        ;;
    reverse-proxy)
        log_info "Режим маскировки: Reverse Proxy -> ${REVERSE_PROXY_URL}"
        ;;
    cloud-storage|status-hub|dev-docs)
        SRC_HTML="${BASE_DIR}/templates/sites/${MASK_TEMPLATE}.html"
        [[ -f "$SRC_HTML" ]] || SRC_HTML="${BASE_DIR}/templates/sites/cloud-storage.html"
        log_info "Развёртывание автономного шаблона ${MASK_TEMPLATE} (${BRAND_NAME})..."
        sed -e "s|__BRAND__|${BRAND_NAME}|g" \
            -e "s|__DOMAIN__|${DOMAIN}|g" \
            -e "s|__REGION__|${NODE_REGION}|g" \
            -e "s|__VERSION__|${APP_VER}|g" \
            -e "s|__BUILD__|${BUILD_ID}|g" \
            "$SRC_HTML" > /var/www/masksite/index.html
        ;;
esac

cat <<'EOF' > /var/www/html/404.html
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>404 Not Found</title>
<style>body{font-family:system-ui,sans-serif;background:#0f172a;color:#cbd5e1;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}main{text-align:center}h1{font-size:2.4rem;margin:0 0 .5rem;color:#f8fafc}p{color:#94a3b8;margin:0}</style>
</head><body><main><h1>404</h1><p>The requested resource was not found.</p></main></body></html>
EOF

if [[ "${ENABLE_GEO_MIRROR:-false}" == "true" ]]; then
    log_info "Настройка зеркала geoip.dat / geosite.dat на Nginx..."
    cat <<'EOF' > /usr/local/sbin/update-geo-mirror.sh
#!/usr/bin/env bash
set -eu
mkdir -p /var/www/geo
BASE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
for f in geoip.dat geosite.dat; do
    if curl -fsSL --max-time 60 "${BASE}/${f}" -o "/var/www/geo/${f}.tmp"; then
        mv "/var/www/geo/${f}.tmp" "/var/www/geo/${f}"
    fi
done
chown -R www-data:www-data /var/www/geo
EOF
    chmod +x /usr/local/sbin/update-geo-mirror.sh
    /usr/local/sbin/update-geo-mirror.sh || log_warn "Не удалось скачать geo-файлы для зеркала, повторится по расписанию."
    echo "30 3 * * * root /usr/local/sbin/update-geo-mirror.sh >/dev/null 2>&1" > /etc/cron.d/update-geo-mirror
    chmod 644 /etc/cron.d/update-geo-mirror
fi

chown -R www-data:www-data /var/www /var/cache/nginx
log_ok "SSL-сертификат ECDSA и сайт-заглушка (${MASK_TEMPLATE}) готовы."
