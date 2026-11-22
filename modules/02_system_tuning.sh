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
curl -fsSL https://nginx.org/keys/nginx_signing.key \
    | gpg --batch --yes --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg
chmod 644 /usr/share/keyrings/nginx-archive-keyring.gpg
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
apt-get install -y -qq nginx
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

configure_doh() {
    log_info "Установка локального DoH-прокси (cloudflared 127.0.0.1:5053)..."
    local arch
    arch=$(dpkg --print-architecture)
    local bin_url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${arch}"
    if ! curl -fsSL --max-time 60 "$bin_url" -o /usr/local/bin/cloudflared; then
        log_warn "Не удалось скачать cloudflared, переключаюсь на нативный DoT."
        configure_dot
        return 0
    fi
    chmod +x /usr/local/bin/cloudflared

    cat <<'EOF' > /etc/systemd/system/cloudflared-doh.service
[Unit]
Description=Cloudflared local DNS-over-HTTPS proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared proxy-dns --address 127.0.0.1 --port 5053 --upstream https://1.1.1.1/dns-query --upstream https://9.9.9.9/dns-query
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now cloudflared-doh.service
    sleep 2

    if dig +short +time=3 @127.0.0.1 -p 5053 github.com >/dev/null 2>&1; then
        mkdir -p /etc/systemd/resolved.conf.d
        cat <<'EOF' > /etc/systemd/resolved.conf.d/10-dot.conf
[Resolve]
DNS=127.0.0.1:5053
FallbackDNS=1.1.1.1 9.9.9.9
EOF
        systemctl restart systemd-resolved 2>/dev/null || true
        sleep 1
        if getent ahosts github.com >/dev/null 2>&1; then
            log_ok "Системный DoH (cloudflared) активен."
            return 0
        fi
    fi

    log_warn "Проверка DoH не пройдена — откат на нативный DoT."
    rm -f /etc/systemd/resolved.conf.d/10-dot.conf
    systemctl disable --now cloudflared-doh.service 2>/dev/null || true
    configure_dot
}

case "${SYSTEM_DNS_MODE:-dot}" in
    dot) configure_dot ;;
    doh) configure_doh ;;
    *)   log_info "Системный DNS оставлен без изменений." ;;
esac

log_ok "Система оптимизирована, официальный Nginx установлен."
