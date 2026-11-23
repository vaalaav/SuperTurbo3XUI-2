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

sed -i -E 's/^[[:space:]]*Port[[:space:]]+/#Port /g' /etc/ssh/sshd_config

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
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
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
    log_info "Установка CrowdSec + nftables firewall bouncer..."
    if curl -fsSL https://install.crowdsec.net | sh >/dev/null 2>&1; then
        apt-get install -y -qq crowdsec crowdsec-firewall-bouncer-nftables
        cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/nginx --force >/dev/null 2>&1 || true

        cat <<'EOF' > /etc/crowdsec/acquis.d/nginx.yaml
filenames:
  - /var/log/nginx/access.log
  - /var/log/nginx/error.log
labels:
  type: nginx
EOF
        cscli bouncers delete firewall-bouncer >/dev/null 2>&1 || true
        BOUNCER_KEY=$(cscli bouncers add firewall-bouncer -o raw)
        sed -i "s|^api_key:.*|api_key: ${BOUNCER_KEY}|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
        sed -i "s|^mode:.*|mode: nftables|" /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
        systemctl enable --now crowdsec crowdsec-firewall-bouncer >/dev/null 2>&1
cscli scenarios remove crowdsecurity/nginx-req-limit-exceeded --force >/dev/null 2>&1 || true
        systemctl restart crowdsec crowdsec-firewall-bouncer
        log_ok "CrowdSec активирован."
    else
        log_warn "Не удалось подключить репозиторий CrowdSec, шаг пропущен."
    fi
fi

# 5. Объединённый nftables-антисканер
if [[ "${ENABLE_ANTISCAN:-true}" == "true" ]]; then
    mkdir -p /etc/nftables.d
    touch /etc/3xui-antiscan-allow.txt
    if [[ -n "${ADMIN_IP:-}" ]]; then
        grep -qxF "$ADMIN_IP" /etc/3xui-antiscan-allow.txt || echo "$ADMIN_IP" >> /etc/3xui-antiscan-allow.txt
    fi

    cat <<'PYEOF' > /usr/local/sbin/update-antiscan.py
#!/usr/bin/env python3
import ipaddress
import json
import os
import re
import subprocess
import sys
import urllib.request

NFT_FILE = "/etc/nftables.d/antiscan.nft"
ALLOW_FILE = "/etc/3xui-antiscan-allow.txt"
STATE_FILE = "/etc/3xui-node/state.env"
MIN_NETS = 30

TEXT_URLS = [
    "https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt",
    "https://raw.githubusercontent.com/shadow-netlab/traffic-guard-lists/main/public/antiscanner.list",
]

STATIC_SCANNERS = [
    "85.142.100.0/24",
    "46.161.48.0/22",
    "95.215.0.0/24",
    "45.91.64.0/24",
    "162.142.125.0/24",
    "167.94.138.0/24",
    "167.94.145.0/24",
    "167.94.146.0/24",
    "167.248.133.0/24",
    "199.45.154.0/24",
    "199.45.155.0/24",
    "206.168.34.0/24",
    "71.6.135.0/24",
    "71.6.146.185/32",
    "71.6.158.166/32",
    "71.6.165.200/32",
    "71.6.167.142/32",
    "66.240.192.138/32",
    "66.240.205.34/32",
    "66.240.236.119/32",
    "80.82.77.33/32",
    "80.82.77.139/32",
    "94.102.49.190/32",
    "198.20.69.74/32",
    "198.20.69.98/32",
    "198.20.70.114/32",
    "198.20.87.98/32",
    "198.20.99.130/32",
    "185.156.73.0/24",
    "193.163.125.0/24",
]


def read_ssh_port() -> int:
    if os.path.isfile(STATE_FILE):
        with open(STATE_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("SSH_PORT="):
                    val = line.split("=", 1)[1].strip().strip("'\"")
                    if val.isdigit():
                        return int(val)
    return 22


def fetch(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode("utf-8", errors="ignore")


def fetch_ripe_as61280():
    out = []
    try:
        raw = fetch("https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS61280")
        data = json.loads(raw)
        for item in data.get("data", {}).get("prefixes", []):
            p = item.get("prefix", "")
            if "." in p:
                out.append(p)
    except Exception as exc:
        print(f"WARN: RIPEstat AS61280 unavailable: {exc}")
    return out


def load_allowlist():
    allowed = set()
    if os.path.isfile(ALLOW_FILE):
        with open(ALLOW_FILE, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.split("#", 1)[0].strip()
                if not line:
                    continue
                try:
                    net = ipaddress.IPv4Network(line, strict=False)
                    if net.is_global:
                        allowed.add(net)
                except ValueError:
                    pass
    return sorted(ipaddress.collapse_addresses(allowed))


def main():
    candidates = list(STATIC_SCANNERS)
    candidates.extend(fetch_ripe_as61280())

    for url in TEXT_URLS:
        try:
            text = fetch(url)
            if "<html" in text.lower():
                continue
            candidates.extend(re.findall(r"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b", text))
        except Exception as exc:
            print(f"WARN: failed {url}: {exc}")

    valid = set()
    for item in candidates:
        try:
            net = ipaddress.IPv4Network(item, strict=False)
            if net.is_global and net.prefixlen >= 16:
                valid.add(net)
        except ValueError:
            continue

    collapsed = list(ipaddress.collapse_addresses(valid))
    if len(collapsed) < MIN_NETS:
        print(f"WARN: получено слишком мало сетей ({len(collapsed)}), сохраняю текущие правила.")
        sys.exit(0)

    allow_nets = load_allowlist()
    ssh_port = read_ssh_port()

    scanners_block = ",\n        ".join(str(n) for n in collapsed)
    allow_set_decl = ""
    allow_rule = ""
    if allow_nets:
        allow_elems = ", ".join(str(n) for n in allow_nets)
        allow_set_decl = f"""
    set allow_v4 {{
        type ipv4_addr
        flags interval
        auto-merge
        elements = {{ {allow_elems} }}
    }}"""
        allow_rule = "        ip saddr @allow_v4 accept\n"

    nft_conf = f"""table inet antiscan
delete table inet antiscan

table inet antiscan {{{allow_set_decl}
    set scanners_v4 {{
        type ipv4_addr
        flags interval
        auto-merge
        elements = {{
        {scanners_block}
        }}
    }}

    chain prerouting {{
        type filter hook prerouting priority -150; policy accept;
        iifname "lo" accept
        ct state established,related accept
{allow_rule}        tcp dport {ssh_port} accept
        ip saddr @scanners_v4 counter drop
    }}
}}
"""
    os.makedirs(os.path.dirname(NFT_FILE), exist_ok=True)
    tmp_file = f"{NFT_FILE}.tmp"
    with open(tmp_file, "w", encoding="utf-8") as f:
        f.write(nft_conf)

    subprocess.run(["nft", "-c", "-f", tmp_file], check=True)
    os.replace(tmp_file, NFT_FILE)
    subprocess.run(["nft", "-f", NFT_FILE], check=True)
    print(f"OK: загружено {len(collapsed)} сжатых IPv4-подсетей сканеров (SSH:{ssh_port} защищён).")


if __name__ == "__main__":
    main()
PYEOF
    chmod +x /usr/local/sbin/update-antiscan.py
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
