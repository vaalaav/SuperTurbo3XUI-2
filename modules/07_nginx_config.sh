#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

NGINX_BACKUP=$(backup_path /etc/nginx "nginx")

if [[ "${MASK_TEMPLATE}" == "reverse-proxy" && -n "${REVERSE_PROXY_URL:-}" ]]; then
    RP_HOST=$(echo "$REVERSE_PROXY_URL" | sed -E 's|^https?://||; s|/.*$||')
    RP_SCHEME=$(echo "$REVERSE_PROXY_URL" | grep -oE '^https?' || echo "https")
    MASK_BLOCK=$(cat <<EOF
        location / {
            limit_req zone=bot burst=20 nodelay;
            limit_conn addr 20;
            proxy_pass ${RP_SCHEME}://${RP_HOST};
            proxy_ssl_server_name on;
            proxy_ssl_name ${RP_HOST};
            proxy_http_version 1.1;
            proxy_ssl_session_reuse off;
            proxy_cache html_zone;
            proxy_cache_valid 200 1d;
            proxy_set_header Host ${RP_HOST};
            proxy_set_header Referer ${RP_SCHEME}://${RP_HOST}/;
            proxy_set_header Accept-Encoding "";
            proxy_set_header X-Real-IP "";
            proxy_set_header X-Forwarded-For "";
            sub_filter '${RP_SCHEME}://${RP_HOST}' 'https://\$host';
            sub_filter '//${RP_HOST}' '//\$host';
            sub_filter_once off;
            sub_filter_types text/html;
        }
EOF
)
else
    MASK_BLOCK=$(cat <<EOF
        location = /api/status {
            default_type application/json;
            return 200 '{"service":"${BRAND_NAME:-CoreNode}","status":"operational","version":"${APP_VER:-2.4.1}","region":"${NODE_REGION:-eu-central-1}"}';
        }
        location = /api/health {
            default_type application/json;
            return 200 '{"ok":true,"uptime":"99.98%"}';
        }
        location = /api/auth {
            limit_req zone=auth_limit burst=2 nodelay;
            default_type application/json;
            return 401 '{"error":"unauthorized","message":"Valid session token required"}';
        }
        location / {
            limit_req zone=bot burst=20 nodelay;
            limit_conn addr 20;
            root /var/www/masksite;
            index index.html;
            try_files \$uri \$uri/ /index.html;
        }
EOF
)
fi

GEO_BLOCK=""
if [[ "${ENABLE_GEO_MIRROR:-false}" == "true" ]]; then
    GEO_BLOCK=$(cat <<EOF
        location ^~ /${GEO_PATH}/ {
            alias /var/www/geo/;
            autoindex off;
            access_log off;
            add_header Cache-Control "public, max-age=3600";
        }
EOF
)
fi

log_info "Генерация /etc/nginx/nginx.conf..."
cat <<EOF > /etc/nginx/nginx.conf
user www-data;
worker_processes auto;
pid /run/nginx.pid;
worker_rlimit_nofile 524288;
error_log /var/log/nginx/error.log warn;

events {
    worker_connections 65535;
    multi_accept on;
    use epoll;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    etag off;
    charset utf-8;
    resolver 1.1.1.1 9.9.9.9 ipv6=off valid=300s;
    http2_recv_buffer_size 4m;

    set_real_ip_from 127.0.0.1;
    real_ip_header proxy_protocol;

    access_log /var/log/nginx/access.log combined buffer=32k flush=30s;

    upstream xray_xhttp {
        server 127.0.0.1:11443;
        keepalive 64;
        keepalive_timeout 1h;
        keepalive_requests 100000;
    }

    proxy_cache_path /var/cache/nginx/html_cache levels=1:2 keys_zone=html_zone:20m max_size=500m inactive=30d use_temp_path=off;

    keepalive_timeout 75s;
    keepalive_requests 100000;
    reset_timedout_connection on;
    client_max_body_size 16m;

    gzip on;
    gzip_vary on;
    gzip_comp_level 2;
    gzip_min_length 512;
    gzip_types text/plain text/css application/json application/javascript text/xml image/svg+xml;

    map \$http_upgrade \$connection_upgrade {
        default upgrade;
        "" close;
    }

    map \$http_user_agent \$badbot_raw {
        default 0;
        "" 1;
        ~*(?:httpclient|go-http-client|python-requests|nuclei|httpx|ffuf|gobuster|sqlmap|nikto|masscan|zgrab|censys|shodan|nmap) 1;
        ~*(?:ahrefs|semrush|mj12bot|yandexbot|googlebot|bingbot|gptbot|claudebot|ccbot|bytespider) 1;
    }

    map \$request_uri \$is_scan_attempt {
        default 0;
        ~*\.(?:php|asp|aspx|jsp|cgi|env|git|sql|bak|ini)\$ 1;
        ~*^/(?:admin|wp-admin|wp-login|phpmyadmin|setup|install|dashboard|config)/ 1;
        ~*(\.\./|/etc/passwd|/proc/) 1;
    }

    map "\$badbot_raw:\$is_scan_attempt:\$request_uri" \$badbot {
        ~^.*:/robots\.txt(\?|\$) 0;
        ~^.*:/${PANEL_PATH}(/|\$) 0;
        ~^.*:/${SUB_PATH}(/|\$) 0;
        ~^.*:/${SUB_JSON_PATH:-__disabled__}(/|\$) 0;
        ~^.*:/${XHTTP_PATH}(/|\$) 0;
        ~^.*:/${GEO_PATH}(/|\$) 0;
        ~(^1:|:1) 1;
        default 0;
    }

    limit_req_zone \$binary_remote_addr zone=bot:1m rate=5r/s;
    limit_req_zone \$binary_remote_addr zone=scan:1m rate=1r/s;
    limit_req_zone \$binary_remote_addr zone=auth_limit:10m rate=3r/m;
    limit_req_zone \$binary_remote_addr zone=panel_limit:10m rate=10r/s;
    limit_conn_zone \$binary_remote_addr zone=addr:1m;
    limit_req_status 429;

    proxy_hide_header Server;
    proxy_hide_header X-Powered-By;

    server {
        listen 80 default_server;
        listen [::]:80 default_server;
        server_name _;
        access_log off;

        location ^~ /.well-known/acme-challenge/ { root /var/www/html; }
        if (\$badbot) { return 444; }
        if (\$host != "${DOMAIN}") { return 444; }
        return 301 https://${DOMAIN}\$request_uri;
    }

    server {
        listen 127.0.0.1:8443 ssl default_server proxy_protocol;
        server_name _;
        ssl_reject_handshake on;
        ssl_certificate /etc/nginx/ssl/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/privkey.pem;
    }

    server {
        listen 127.0.0.1:8443 ssl proxy_protocol;
        http2 on;
        http2_max_concurrent_streams 1024;
        http2_chunk_size 16k;
        server_name ${DOMAIN};

        ssl_certificate /etc/nginx/ssl/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/nginx/ssl/${DOMAIN}/privkey.pem;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_prefer_server_ciphers off;
        ssl_session_cache shared:SSL:10m;
        ssl_session_timeout 15m;
        ssl_early_data off;

        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Frame-Options "SAMEORIGIN" always;
        add_header Referrer-Policy "strict-origin-when-cross-origin" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;

        if (\$is_scan_attempt) { return 404; }
        if (\$badbot) { return 404; }
        if (\$request_method !~ ^(GET|HEAD|POST|PUT|DELETE|OPTIONS)\$) { return 405; }
        if (\$host != "${DOMAIN}") { return 444; }

        proxy_intercept_errors on;
        error_page 400 403 404 405 @notfound;

        location = /${PANEL_PATH} { return 301 /${PANEL_PATH}/; }
        location /${PANEL_PATH}/ {
            proxy_pass http://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}/;
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_buffering off;
            proxy_request_buffering off;
            proxy_intercept_errors off;
            access_log off;
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        location = /${SUB_PATH}  { return 404; }
        location = /${SUB_PATH}/ { return 404; }
        location ^~ /${SUB_PATH}/ {
            proxy_pass http://127.0.0.1:${SUB_PORT}/${SUB_PATH}/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_intercept_errors off;
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        location = /${SUB_JSON_PATH:-__disabled__}/ { return 404; }
        location ^~ /${SUB_JSON_PATH:-__disabled__}/ {
            proxy_pass http://127.0.0.1:${SUB_PORT}/${SUB_JSON_PATH:-__disabled__}/;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            add_header Cache-Control "no-store, no-cache, must-revalidate";
        }

        location /${XHTTP_PATH}/ {
            proxy_pass http://xray_xhttp;
            proxy_http_version 2;
            proxy_buffering off;
            proxy_request_buffering off;
            gzip off;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$remote_addr;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_read_timeout 1h;
            proxy_send_timeout 1h;
            client_body_timeout 1h;
            send_timeout 1h;
            proxy_socket_keepalive on;
            proxy_next_upstream off;
            client_max_body_size 0;
            proxy_max_temp_file_size 0;
            access_log off;
            error_log /dev/null crit;
            error_page 400 502 503 504 =404 @notfound;
        }

${GEO_BLOCK}

        include /etc/nginx/conf.d/node-ext/*.conf;

${MASK_BLOCK}

        location = /robots.txt {
            default_type text/plain;
            access_log off;
            return 200 "User-agent: *\nDisallow: /\n";
        }
        location ~ /\. { deny all; }
        location @notfound {
            limit_req zone=scan burst=3 nodelay;
            root /var/www/html;
            rewrite ^ /404.html break;
        }
    }
}
EOF

if ! nginx -t; then
    log_warn "Ошибка синтаксиса Nginx! Откат из ${NGINX_BACKUP}..."
    cp -a "${NGINX_BACKUP}/nginx/." /etc/nginx/
    nginx -t || true
    log_err "Конфигурация Nginx не прошла проверку."
fi

systemctl enable --now nginx >/dev/null 2>&1
systemctl restart nginx
systemctl restart x-ui
sleep 2
log_ok "Nginx (127.0.0.1:8443) и Xray/3x-ui (0.0.0.0:443) запущены."
