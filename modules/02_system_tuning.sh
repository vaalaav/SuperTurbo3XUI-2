#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

export DEBIAN_FRONTEND=noninteractive
# shellcheck disable=SC1091
. /etc/os-release

log_info "Установка базовых пакетов..."
apt-get update -qq
apt-get install -y -qq curl wget gnupg2 ca-certificates lsb-release \
    sqlite3 python3 jq socat certbot ufw fail2ban nftables cron openssl dnsutils

log_info "Подключение официального репозитория nginx.org (${ID})..."
# Отпечаток ключа подписи пакетов, опубликованный на nginx.org/en/linux_packages.html.
NGINX_KEY_FPR="573BFD6B3D8FBC641079A6ABABF5BD827BD9BF62" # gitleaks:allow — публичный отпечаток ключа, не секрет
NGINX_KEY_TMP=$(mktemp)
trap 'rm -f "$NGINX_KEY_TMP"' EXIT
curl -fsSL --retry 3 https://nginx.org/keys/nginx_signing.key -o "$NGINX_KEY_TMP" \
    || log_err "Не удалось скачать ключ подписи nginx.org."
if ! gpg --show-keys --with-colons "$NGINX_KEY_TMP" 2>/dev/null | awk -F: '/^fpr/ {print $10}' | grep -qx "$NGINX_KEY_FPR"; then
    log_err "Отпечаток ключа nginx.org не совпал с ${NGINX_KEY_FPR} — репозиторий не подключён."
fi
gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg "$NGINX_KEY_TMP"
chmod 644 /usr/share/keyrings/nginx-archive-keyring.gpg

CODENAME=$(lsb_release -cs)
if [[ "$ID" == "debian" ]]; then
    NGINX_REPO="https://nginx.org/packages/debian"
else
    NGINX_REPO="https://nginx.org/packages/ubuntu"
fi

echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] ${NGINX_REPO} ${CODENAME} nginx" \
    > /etc/apt/sources.list.d/nginx.list
printf "Package: *\nPin: origin nginx.org\nPin: release o=nginx\nPin-Priority: 900\n" \
    > /etc/apt/preferences.d/99nginx
chmod 644 /etc/apt/sources.list.d/nginx.list /etc/apt/preferences.d/99nginx

apt-get update -qq
if dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q "install ok installed" && [[ ! -f /etc/nginx/mime.types ]]; then
    apt-get install --reinstall -y -qq -o Dpkg::Options::="--force-confmiss" nginx
else
    apt-get install -y -qq -o Dpkg::Options::="--force-confmiss" nginx
fi
id -u www-data >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin www-data

TOTAL_RAM_MB=$(awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo)
SWAP_TOTAL_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
if (( TOTAL_RAM_MB < 1500 && SWAP_TOTAL_KB == 0 )) && [[ ! -f /swapfile ]]; then
    log_info "Создание swap-файла 1 ГБ для стабильной работы..."
    if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || true
        swapon /swapfile 2>/dev/null || true
        grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_ok "Swap 1 ГБ активирован."
    else
        log_warn "Swap недоступен (ограничение виртуализации)."
    fi
fi

log_info "Применение sysctl-тюнинга (99-xray-custom.conf)..."
cat <<'EOF' > /etc/sysctl.d/99-xray-custom.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
vm.swappiness = 10

net.ipv4.ip_local_port_range = 1024 65535
net.core.netdev_max_backlog = 16384
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535

net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_max_tw_buckets = 524288
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 212992
net.core.wmem_default = 212992
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 131072 16777216
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_mtu_probe_floor = 1024
net.ipv4.tcp_notsent_lowat = 16384

fs.file-max = 2097152
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
sysctl --system >/dev/null 2>&1 || log_warn "Часть параметров sysctl пропущена (ограничение контейнера)."

mkdir -p /etc/systemd/system/nginx.service.d
cat <<'EOF' > /etc/systemd/system/nginx.service.d/limits.conf
[Service]
LimitNOFILE=524288
EOF
systemctl daemon-reload

configure_dot() {
    if ! systemctl list-unit-files systemd-resolved.service >/dev/null 2>&1; then
        log_warn "systemd-resolved не найден, системный DNS оставлен без изменений."
        return 0
    fi
    disable_doh_proxy
    log_info "Настройка нативного DNS-over-TLS (systemd-resolved)..."
    mkdir -p /etc/systemd/resolved.conf.d
    cat <<'EOF' > /etc/systemd/resolved.conf.d/10-dot.conf
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 9.9.9.9#dns.quad9.net
FallbackDNS=8.8.8.8#dns.google
DNSOverTLS=opportunistic
DNSSEC=allow-downgrade
EOF
    systemctl enable --now systemd-resolved >/dev/null 2>&1 || true
    systemctl restart systemd-resolved
    sleep 1
    if ! getent ahosts github.com >/dev/null 2>&1; then
        log_warn "Сбой резолвинга после включения DoT — автоматический откат!"
        rm -f /etc/systemd/resolved.conf.d/10-dot.conf
        systemctl restart systemd-resolved || true
    else
        log_ok "Системный DoT (opportunistic) активен и проверен."
    fi
}

# Локальный DoH-прокси прежних версий проекта. `cloudflared proxy-dns` удалён из cloudflared
# начиная с 2026.2.0, и такая служба не запускается — при любом режиме DNS она убирается.
remove_legacy_cloudflared() {
    [[ -f /etc/systemd/system/cloudflared-doh.service || -x /usr/local/bin/cloudflared ]] || return 0
    systemctl disable --now cloudflared-doh.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/cloudflared-doh.service /usr/local/bin/cloudflared
    systemctl daemon-reload
    log_info "Удалён прежний DoH-прокси cloudflared (команда proxy-dns больше не поддерживается)."
}

disable_doh_proxy() {
    systemctl disable --now 3xui-node-doh.service >/dev/null 2>&1 || true
}

# Локальный DoH-прокси: dnscrypt-proxy из репозитория дистрибутива на 127.0.0.1:5053, серверы
# Cloudflare и Quad9 заданы штампами с IP-адресами — без загрузки списков и без bootstrap-DNS.
# Пакетные socket- и resolvconf-юниты отключаются: они слушают 127.0.2.1:53 и правят resolv.conf.
configure_doh() {
    log_info "Установка локального DoH-прокси (dnscrypt-proxy, 127.0.0.1:5053)..."
    if ! apt-get install -y -qq dnscrypt-proxy >/dev/null; then
        log_warn "Не удалось установить dnscrypt-proxy, переключаюсь на нативный DoT."
        configure_dot
        return 0
    fi
    systemctl disable --now dnscrypt-proxy.socket dnscrypt-proxy.service dnscrypt-proxy-resolvconf.service >/dev/null 2>&1 || true
    systemctl mask dnscrypt-proxy.socket dnscrypt-proxy.service dnscrypt-proxy-resolvconf.service >/dev/null 2>&1 || true

    install -d -m 755 /etc/3xui-node
    cat <<'EOF' > /etc/3xui-node/dnscrypt-proxy.toml
# Создано модулем 02 проекта 3xui-node: системный DoH через Cloudflare и Quad9.
listen_addresses = ['127.0.0.1:5053']
server_names = ['cloudflare-doh', 'quad9-doh']
ipv4_servers = true
ipv6_servers = false
dnscrypt_servers = false
doh_servers = true
require_dnssec = false
require_nolog = false
require_nofilter = false
lb_strategy = 'p2'
timeout = 5000
keepalive = 30
cache = true
ignore_system_dns = true

[static]
  # DoH, 1.1.1.1, cloudflare-dns.com, /dns-query
  [static.'cloudflare-doh']
  stamp = 'sdns://AgMAAAAAAAAABzEuMS4xLjEAEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5'
  # DoH, 9.9.9.9, dns.quad9.net, /dns-query
  [static.'quad9-doh']
  stamp = 'sdns://AgMAAAAAAAAABzkuOS45LjkADWRucy5xdWFkOS5uZXQKL2Rucy1xdWVyeQ'
EOF
    chmod 644 /etc/3xui-node/dnscrypt-proxy.toml
    if ! /usr/sbin/dnscrypt-proxy -config /etc/3xui-node/dnscrypt-proxy.toml -check >/dev/null 2>&1; then
        log_warn "Конфигурация dnscrypt-proxy не прошла проверку, переключаюсь на нативный DoT."
        configure_dot
        return 0
    fi

    cat <<'EOF' > /etc/systemd/system/3xui-node-doh.service
[Unit]
Description=Локальный DoH-прокси (dnscrypt-proxy, 127.0.0.1:5053)
After=network-online.target
Wants=network-online.target
Before=nss-lookup.target

[Service]
ExecStart=/usr/sbin/dnscrypt-proxy -config /etc/3xui-node/dnscrypt-proxy.toml
User=_dnscrypt-proxy
Restart=on-failure
RestartSec=3
CacheDirectory=dnscrypt-proxy
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
NoNewPrivileges=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectControlGroups=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now 3xui-node-doh.service >/dev/null 2>&1 || true

    # Прокси отвечает, когда дождётся хотя бы одного доступного сервера.
    local i ok=false
    for i in $(seq 1 15); do
        if dig +short +time=2 +tries=1 @127.0.0.1 -p 5053 github.com 2>/dev/null | grep -q .; then ok=true; break; fi
        sleep 1
    done
    if $ok; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat <<'EOF' > /etc/systemd/resolved.conf.d/10-dot.conf
[Resolve]
DNS=127.0.0.1:5053
FallbackDNS=1.1.1.1 9.9.9.9
EOF
        systemctl restart systemd-resolved 2>/dev/null || true
        sleep 1
        if getent ahosts github.com >/dev/null 2>&1; then
            log_ok "Системный DoH (dnscrypt-proxy) активен."
            return 0
        fi
    fi

    log_warn "Проверка DoH не пройдена — откат на нативный DoT."
    rm -f /etc/systemd/resolved.conf.d/10-dot.conf
    disable_doh_proxy
    configure_dot
}

remove_legacy_cloudflared
case "${SYSTEM_DNS_MODE:-dot}" in
    dot) configure_dot ;;
    doh) configure_doh ;;
    *)   log_info "Системный DNS оставлен без изменений." ;;
esac

log_ok "Система оптимизирована, официальный Nginx установлен."
