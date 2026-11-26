#!/usr/bin/env bash
set -eu
BASE_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source "${BASE_DIR}/lib/common.sh"
require_root
load_state

# 1. Настройка SSH (миграция ssh.socket -> ssh.service, Termius KeepAlive, откат)
log_info "Настройка OpenSSH (порт: ${SSH_PORT})..."
SSH_BACKUP=$(backup_path /etc/ssh "ssh")
mkdir -p /root/.ssh /etc/ssh/sshd_config.d
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

SSH_KEYS_FILE="${STATE_DIR}/pending_ssh_keys.pub"
if [[ -s "$SSH_KEYS_FILE" ]]; then
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        grep -qxF "$key" /root/.ssh/authorized_keys || echo "$key" >> /root/.ssh/authorized_keys
    done < "$SSH_KEYS_FILE"
    rm -f "$SSH_KEYS_FILE"
    log_ok "Публичные SSH-ключи добавлены в /root/.ssh/authorized_keys."
fi

for ssh_cfg in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
    [[ -f "$ssh_cfg" && "$ssh_cfg" != "/etc/ssh/sshd_config.d/00-custom-ssh.conf" ]] || continue
    sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#Port /g' "$ssh_cfg"
done

cat <<EOF > /etc/ssh/sshd_config.d/00-custom-ssh.conf
# Managed by 3xui-node installer
Port ${SSH_PORT}
ClientAliveInterval 30
ClientAliveCountMax 6
MaxAuthTries 4
LoginGraceTime 30
EOF

if [[ "${SSH_LOCK_PASS:-false}" == "true" ]]; then
    if [[ -s /root/.ssh/authorized_keys ]]; then
        cat <<'EOF' > /etc/ssh/sshd_config.d/00-keys-only.conf
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
        log_ok "Вход по паролю отключён (00-keys-only.conf)."
    else
        log_warn "authorized_keys пуст — пароль не отключён во избежание потери доступа."
    fi
fi

mkdir -p /run/sshd
if ! sshd -t 2>/dev/null; then
    log_warn "Ошибка синтаксиса sshd_config! Откат из ${SSH_BACKUP}..."
    cp -a "${SSH_BACKUP}/ssh/." /etc/ssh/
    log_err "Настройка SSH прервана из-за ошибки конфига."
fi

if ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${SSH_PORT}/tcp" comment 'SSH-new' >/dev/null 2>&1 || true
fi

SSH_UNIT="ssh.service"
systemctl list-unit-files sshd.service >/dev/null 2>&1 && ! systemctl list-unit-files ssh.service >/dev/null 2>&1 && SSH_UNIT="sshd.service"

if [[ "${SSH_PORT_CHANGED:-false}" == "true" && "${NON_INTERACTIVE:-false}" != "true" ]]; then
    cat <<EOF > /usr/local/sbin/ssh-port-rollback.sh
#!/usr/bin/env bash
cp -a "${SSH_BACKUP}/ssh/." /etc/ssh/
systemctl restart ${SSH_UNIT} || true
ufw allow "${CUR_SSH_PORT}/tcp" >/dev/null 2>&1 || true
EOF
    chmod +x /usr/local/sbin/ssh-port-rollback.sh
    systemctl stop ssh-port-rollback.timer ssh-port-rollback.service 2>/dev/null || true
    systemctl reset-failed ssh-port-rollback.timer ssh-port-rollback.service 2>/dev/null || true
    systemd-run --unit=ssh-port-rollback --on-active=180s /usr/local/sbin/ssh-port-rollback.sh >/dev/null 2>&1 || true
fi

if systemctl list-unit-files ssh.socket >/dev/null 2>&1; then
    systemctl disable --now ssh.socket >/dev/null 2>&1 || true
fi
systemctl enable --now "$SSH_UNIT" >/dev/null 2>&1 || true
systemctl restart "$SSH_UNIT"
sleep 1

if ! ss -tln | awk '{print $4}' | grep -qE "(:|\\])${SSH_PORT}$"; then
    log_warn "SSH не открылся на порту ${SSH_PORT}! Выполняю откат..."
    cp -a "${SSH_BACKUP}/ssh/." /etc/ssh/
    systemctl restart "$SSH_UNIT" || true
    log_err "Не удалось перенести SSH на порт ${SSH_PORT}."
fi

if [[ "${SSH_PORT_CHANGED:-false}" == "true" && "${NON_INTERACTIVE:-false}" != "true" ]]; then
    echo -e "\n${YELLOW}${BOLD}ПРОВЕРКА НОВОГО SSH ПОРТА (${SSH_PORT}):${NC}"
    echo "  Откройте 2-ю вкладку в Termius и подключитесь:"
    echo -e "  ${CYAN}ssh -p ${SSH_PORT} root@${SERVER_IP}${NC}"
    echo "  (Автооткат на порт ${CUR_SSH_PORT} сработает через 180 сек)"
    if read -t 170 -erp "  Подключение прошло успешно? Подтвердить [y/N]: " SSH_OK && [[ "${SSH_OK:-N}" =~ ^[Yy]$ ]]; then
        systemctl stop ssh-port-rollback.timer ssh-port-rollback.service 2>/dev/null || true
        rm -f /usr/local/sbin/ssh-port-rollback.sh
        log_ok "Новый SSH-порт ${SSH_PORT} подтверждён."
    else
        log_warn "Подтверждение не получено — возвращаю порт ${CUR_SSH_PORT}."
        bash /usr/local/sbin/ssh-port-rollback.sh || true
        systemctl stop ssh-port-rollback.timer 2>/dev/null || true
        rm -f /usr/local/sbin/ssh-port-rollback.sh
        SSH_PORT="$CUR_SSH_PORT"
        save_var SSH_PORT "$SSH_PORT"
        save_var SSH_PORT_CHANGED "false"
    fi
fi

# 2. UFW (только SSH, 80/tcp, 443/tcp)
log_info "Настройка UFW (SSH:${SSH_PORT}, 80/tcp, 443/tcp)..."
backup_path /etc/ufw "ufw" >/dev/null
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP ACME' >/dev/null
ufw allow 443/tcp comment 'HTTPS Reality/XHTTP' >/dev/null
ufw --force enable >/dev/null

# 3. Fail2Ban (nftables + явный journalmatch ssh.service + polling nginx)
log_info "Настройка Fail2Ban..."
if ! command -v fail2ban-server >/dev/null 2>&1 || [[ ! -d /etc/fail2ban/filter.d ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -o Dpkg::Options::="--force-confmiss" -y -qq fail2ban
fi
mkdir -p /var/log/nginx
touch /var/log/nginx/access.log /var/log/nginx/error.log

cat <<EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 24h
findtime = 10m
maxretry = 4
banaction = nftables-multiport

[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
journalmatch = _SYSTEMD_UNIT=${SSH_UNIT} + _COMM=sshd + _COMM=sshd-session
maxretry = 4
bantime = 24h

[nginx-botsearch]
enabled = true
port = http,https
backend = polling
logpath = /var/log/nginx/access.log
maxretry = 10
findtime = 5m
bantime = 12h
EOF

systemctl enable --now fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# 4. CrowdSec (опционально)
if [[ "${ENABLE_CROWDSEC:-false}" == "true" ]]; then
    install_crowdsec || log_warn "Не удалось подключить репозиторий или установить CrowdSec, шаг пропущен."
fi

# 5. Объединённый nftables-антисканер
if [[ "${ENABLE_ANTISCAN:-true}" == "true" ]]; then
    mkdir -p /etc/nftables.d
    touch /etc/3xui-antiscan-allow.txt
    if [[ -n "${ADMIN_IP:-}" ]]; then
        grep -qxF "$ADMIN_IP" /etc/3xui-antiscan-allow.txt || echo "$ADMIN_IP" >> /etc/3xui-antiscan-allow.txt
    fi

    install -m 755 "${BASE_DIR}/lib/update_antiscan.py" /usr/local/sbin/update-antiscan.py
    /usr/local/sbin/update-antiscan.py || log_warn "Первичное обновление антисканера прошло с предупреждением."

    cat <<'EOF' > /etc/systemd/system/antiscan-restore.service
[Unit]
Description=Restore nftables antiscan rules on boot
After=network-online.target nftables.service ufw.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nft -f /etc/nftables.d/antiscan.nft
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    cat <<'EOF' > /etc/systemd/system/antiscan-update.service
[Unit]
Description=Update nftables antiscan blocklist
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/update-antiscan.py
EOF

    cat <<'EOF' > /etc/systemd/system/antiscan-update.timer
[Unit]
Description=Refresh nftables antiscan every 6 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable antiscan-restore.service >/dev/null 2>&1 || true
    systemctl enable --now antiscan-update.timer >/dev/null 2>&1 || true
fi

log_ok "Стек сетевой защиты (SSH, UFW, Fail2Ban, Antiscan) настроен."
