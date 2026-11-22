<div align="center">

# 3X-UI Modular Node Deploy

**Модульное развёртывание защищённой зарубежной VPN-ноды на базе 3x-ui ≥ v3.11.0**

![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?style=for-the-badge&logo=debian&logoColor=white)
![3x-ui](https://img.shields.io/badge/3x--ui-%E2%89%A5%203.11.0-2563EB?style=for-the-badge)
![Security](https://img.shields.io/badge/Anti--DPI-Reality%20%2B%20XHTTP-10B981?style=for-the-badge)

</div>

---

## Быстрый старт

Запустите на чистом VPS от имени `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/SuperTurbo3XUI-2/main/bootstrap.sh)
```

---

## Архитектура ноды

- **Единый вход `443/tcp` (Self-Steal):** снаружи открыты только ваш порт `SSH`, `80/tcp` (ACME webroot) и `443/tcp`.
- **Два инбаунда и 1 готовый клиент (через REST API 3x-ui ≥ 3.11.0):**
  1. `VLESS + TCP/RAW + Reality + Vision` (`0.0.0.0:443` → локальный Nginx `127.0.0.1:8443` с `xver: 1`).
  2. `VLESS + XHTTP (packet-up + XMUX + обфускация паддинга)` на `127.0.0.1:11443` за Nginx HTTP/2.
- **Защита от ТСПУ и Active Probing:**
  - `ssl_reject_handshake on` для обращений по IP или чужому SNI.
  - Объединённый `nftables`-антисканер (RIPEstat AS61280 ГРЧЦ, C24Be, CyberOK Skipa, shadow-netlab, F6, Censys, Shodan) с автообновлением каждые 6 часов и защитой SSH-порта.
  - `UFW`, `Fail2Ban` (`ssh.service` + `nginx-botsearch`), опциональный `CrowdSec`.
  - Автоматическая блокировка исходящего трафика с VPS в РФ (`blackhole`).
- **Опциональный AI-модуль:** встроенный **Cloudflare WARP** (0 МБ лишней RAM), **Psiphon** в Docker (`--network host`, `127.0.0.1:1080`, анти-QUIC для Gemini) или комбинированный режим.
- **Подписка для Happ и INCY:** опциональный профиль `RU напрямую / мир через VPN` (`Happ Routing`) и локальное зеркало `geoip.dat` / `geosite.dat` на Nginx.
- **Удобный SSH под два устройства Termius:** интерактивная смена порта (миграция `ssh.socket` → `ssh.service`) с таймером автоотката на 180 сек, добавление нескольких ключей и отложенное отключение пароля через `my3xui ssh`.

---

## Структура проекта

```text
├── bootstrap.sh               # Загрузчик проекта в /opt/3xui-node
├── install.sh                 # Оркестратор (--only, --from, --resume, --config)
├── lib/
│   ├── common.sh              # Логи, state.env, бэкапы, автоопределение SSH
│   └── xui_api.py             # Работа с 3x-ui >= 3.11.0 через REST API
├── modules/
│   ├── 01_preflight.sh        # ОС, DoH-проверка DNS, мастер параметров
│   ├── 02_system_tuning.sh    # nginx.org, BBR+fq, swap, DoT / опц. DoH
│   ├── 03_security_stack.sh   # SSH (откат 180с), UFW, Fail2Ban, CrowdSec, nftables
│   ├── 04_ssl_and_mask.sh     # Certbot ECDSA (webroot) + заглушка + geo-зеркало
│   ├── 05_install_3xui.sh     # 3x-ui 3.11+, Reality + XHTTP + 1 клиент + Happ
│   ├── 06_ai_routing.sh       # Опциональный WARP / Psiphon
│   ├── 07_nginx_config.sh     # Nginx 127.0.0.1:8443 proxy_protocol + HTTP/2 XHTTP
│   └── 08_cli_and_audit.sh    # Установка my3xui, MOTD и сквозной E2E тест VPN
├── templates/sites/           # Автономные шаблоны заглушек (cloud-storage, status-hub, dev-docs)
└── cli/my3xui                 # Утилита администрирования
```

---

## Управление (`my3xui`)

```bash
my3xui                      # Интерактивное меню (адаптировано под мобильный Termius)
my3xui info                 # CPU, RAM, Swap, NVMe/SSD/HDD, версии 3x-ui и Xray
my3xui creds                # URL панели, логин, пароль, подписка и ссылки vless://
my3xui audit                # Проверка портов, маскировки, TLS по IP и E2E тест VPN
my3xui security             # Статус UFW, Fail2Ban, CrowdSec и счётчик antiscan
my3xui ssh status           # Порт SSH, ключи Termius, статус парольной авторизации
my3xui ssh add-key          # Добавить публичный ключ 2-го устройства Termius
my3xui ssh lock-password    # Отключить вход по паролю после проверки обоих устройств
my3xui run 07_nginx_config  # Перезапустить отдельный модуль
my3xui self-update          # Обновить модули из GitHub
my3xui clean                # Полная очистка сервера (с сохранением SSH)
```
