<div align="center">

# 3X-UI Modular Node Deploy

**Модульное развёртывание защищённой зарубежной VPN-ноды на базе 3x-ui ≥ v3.11.0**

[![CI](https://github.com/vaalaav/SuperTurbo3XUI-2/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/vaalaav/SuperTurbo3XUI-2/actions/workflows/ci.yml)
![Ubuntu](https://img.shields.io/badge/Ubuntu-24.04%20%7C%2026.04-E95420?style=for-the-badge&logo=ubuntu&logoColor=white)
![Debian](https://img.shields.io/badge/Debian-12%20%7C%2013-A81D33?style=for-the-badge&logo=debian&logoColor=white)
![3x-ui](https://img.shields.io/badge/3x--ui-%E2%89%A5%203.11.0-2563EB?style=for-the-badge)
![Security](https://img.shields.io/badge/Anti--DPI-Reality%20%2B%20XHTTP-10B981?style=for-the-badge)

</div>

---

## Содержание

- [Быстрый старт](#быстрый-старт)
- [Архитектура ноды](#архитектура-ноды)
- [Структура проекта](#структура-проекта)
- [Управление (`my3xui`)](#управление-my3xui)
- [Версия 3x-ui](#версия-3x-ui)
- [API-токен панели](#api-токен-панели)
- [Устранение неполадок](#устранение-неполадок)
- [Известные ограничения](#известные-ограничения)
- [Разработка и проверки](#разработка-и-проверки)

---

## Быстрый старт

Запустите на чистом VPS от имени `root`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/SuperTurbo3XUI-2/main/bootstrap.sh)
```

Мастер задаст вопросы (домен, SSH, DNS, заглушка, защита, AI-модуль, подписка) и покажет сводку перед установкой. Аргументы после `bootstrap.sh` передаются в `install.sh`, например:

```bash
# Зафиксировать другую версию 3x-ui (не ниже v3.11.0)
bash <(curl -fsSL https://raw.githubusercontent.com/vaalaav/SuperTurbo3XUI-2/main/bootstrap.sh) --xui-version v3.11.0
```

### Параметры `install.sh`

| Параметр | Назначение |
|---|---|
| `--only <модуль>` | Запустить один модуль, например `05_install_3xui` |
| `--from <модуль>` | Запустить, начиная с указанного модуля |
| `--resume` | Продолжить с модуля после последнего успешного |
| `--config <файл>` | Неинтерактивный запуск с готовым `state.env` (мастер пропускается) |
| `--xui-version <тег>` | Версия 3x-ui — тег релиза вида `v3.11.0`, не ниже `v3.11.0`; сохраняется в `state.env` |
| `--list` | Список модулей |

<sub>[↑ К содержанию](#содержание)</sub>


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
  - Опциональный **лимит устройств на клиента** (IP Limit 3x-ui, jail `3x-ipl`) — вопрос в мастере, по умолчанию включён.
  - Автоматическая блокировка исходящего трафика с VPS в РФ (`blackhole`).
- **Опциональный AI-модуль:** встроенный **Cloudflare WARP** (0 МБ лишней RAM), **Psiphon** в Docker (`--network host`, `127.0.0.1:1080`, анти-QUIC для Gemini) или комбинированный режим.
- **Подписка для Happ и INCY:** опциональный профиль `RU напрямую / мир через VPN` (`Happ Routing`) и локальное зеркало `geoip.dat` / `geosite.dat` на Nginx.
- **Панель 3x-ui только на `127.0.0.1`, без собственного TLS** — снаружи она доступна через Nginx по секретному пути. Проект работает с панелью через её REST API по постоянному токену `3xui-node` (хранится в `state.env`).
- **Удобный SSH под два устройства Termius:** интерактивная смена порта (миграция `ssh.socket` → `ssh.service`) с таймером автоотката на 180 сек, добавление нескольких ключей и отложенное отключение пароля через `my3xui ssh`.

<sub>[↑ К содержанию](#содержание)</sub>


---

## Структура проекта

```text
├── bootstrap.sh               # Загрузчик проекта в /opt/3xui-node
├── install.sh                 # Оркестратор (--only, --from, --resume, --config, --xui-version)
├── lib/
│   ├── common.sh              # Логи, state.env, бэкапы, SSH, версия 3x-ui, API-токен
│   ├── xui_api.py             # Работа с 3x-ui >= 3.11.0 через REST API
│   └── xui_v311_post.py       # Настройки подписки (JSON, Happ/INCY) и шаблон Xray
├── modules/
│   ├── 01_preflight.sh        # ОС, DoH-проверка DNS, мастер параметров
│   ├── 02_system_tuning.sh    # nginx.org, BBR+fq, swap, DoT / опц. DoH
│   ├── 03_security_stack.sh   # SSH (откат 180с), UFW, Fail2Ban, CrowdSec, nftables
│   ├── 04_ssl_and_mask.sh     # Certbot ECDSA (webroot) + заглушка + geo-зеркало
│   ├── 05_install_3xui.sh     # Установка/обновление 3x-ui, Reality + XHTTP + 1 клиент + Happ
│   ├── 06_ai_routing.sh       # Опциональный WARP / Psiphon
│   ├── 07_nginx_config.sh     # Nginx 127.0.0.1:8443 proxy_protocol + HTTP/2 XHTTP
│   └── 08_cli_and_audit.sh    # Установка my3xui, MOTD и сквозной E2E тест VPN
├── templates/sites/           # Автономные шаблоны заглушек (cloud-storage, status-hub, dev-docs)
└── cli/my3xui                 # Утилита администрирования
```

<sub>[↑ К содержанию](#содержание)</sub>


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

<sub>[↑ К содержанию](#содержание)</sub>


---

## Версия 3x-ui

Проект работает с REST API 3x-ui **3.11** (клиенты, хосты, API-токены), поэтому более старые версии не поддерживаются.

- По умолчанию ставится проверенный релиз **v3.11.0**; другую версию задаёт `--xui-version` или `XUI_VERSION` в `state.env`.
- Модуль `05_install_3xui` запускает официальный установщик 3x-ui того же релиза в неинтерактивном режиме: логин, пароль, порт и путь панели передаются из `state.env`, TLS панели выключен (его терминирует Nginx), база — SQLite.
- Если 3x-ui уже стоит и версия ≥ 3.11.0, установщик не запускается — обновляется только конфигурация.
- Если стоит версия ниже 3.11.0, панель останавливается, `/etc/x-ui` копируется в `/root/3xui-node-backups/x-ui-db-<дата>`, затем панель обновляется. Клиенты и инбаунды сохраняются.

<sub>[↑ К содержанию](#содержание)</sub>


## API-токен панели

Модули 05 и 06 обращаются к панели по именованному токену `3xui-node`. Он выпускается один раз, хранится в `/etc/3xui-node/state.env` (права 600) как `XUI_API_TOKEN` и переиспользуется. Если токен удалить в панели, следующий запуск модуля выпустит новый с тем же именем — токены не накапливаются.

<sub>[↑ К содержанию](#содержание)</sub>


---

## Устранение неполадок

| Где смотреть | Что там |
|---|---|
| `/var/log/3xui-node-install.log` | Сообщения модулей проекта |
| `/var/log/3xui-node-xui-install.log` | Полный вывод официального установщика 3x-ui (права 600: содержит учётные данные панели) |
| `journalctl -u x-ui -n 100` | Журнал панели и Xray |
| `fail2ban-client status 3x-ipl` | Состояние лимита устройств (если включён) |

- **«Нужна 3x-ui не ниже v3.11.0» или «Версия 3x-ui должна быть тегом релиза»** — в `--xui-version` или `state.env` указана неподходящая версия. Нужен тег вида `v3.11.0`.
- **«Установщик 3x-ui завершился с ошибкой»** — последние строки вывода показываются сразу, полный вывод в `/var/log/3xui-node-xui-install.log`. Чаще всего это недоступность GitHub с сервера.
- **«Панель 3x-ui не ответила на 127.0.0.1:… за 30 с»** — после перезапуска панель не начала отвечать; причину покажет `journalctl -u x-ui`, повторный запуск: `my3xui run 05_install_3xui`.
- **«Xray не запустился после применения конфигурации»** — панель приняла настройки, но Xray с ними не стартует; причина в тексте ошибки и в `journalctl -u x-ui`.
- **«Проверка ссылок панели не пройдена»** — панель отдаёт клиенту ссылки не на `домен:443` или с другим UUID; модуль останавливается, чтобы не выдать нерабочую подписку.
- **«Сохранённый API-токен отклонён панелью — выпускаю новый»** — это предупреждение, не ошибка: токен восстанавливается автоматически.

<sub>[↑ К содержанию](#содержание)</sub>


## Известные ограничения

- Официальный установщик 3x-ui создаёт собственный админ-токен `install` и сохраняет его в `/etc/x-ui/install-result.env` (права 600). Проект его не использует.
- Если регистрация WARP в модуле 06 не удалась, модуль сообщает об этом предупреждением, но маршруты WARP не добавляются.

<sub>[↑ К содержанию](#содержание)</sub>

---

## Разработка и проверки

Каждый push и pull request проходит CI (`.github/workflows/ci.yml`):

| Проверка | Что делает | Локально |
|---|---|---|
| Линтеры | shellcheck (0 предупреждений), ruff (`ruff.toml`), actionlint | `bash tests/lint.sh` |
| Секреты | gitleaks по всей истории и рабочему дереву | — |
| Модульные тесты | `tests/unit/`: проверка ссылок панели, перенос AI-маршрутов, вход в API (токен → пароль), `version_ge`, `save_var` со спецсимволами | `bash tests/unit.sh` |
| Модуль 05 на чистой машине | официальный установщик 3x-ui на раннере с systemd; сценарии `fresh` (установка, повтор, восстановление токена), `upgrade` (с 3.10.2 с сохранением данных), `no-ip-limit` | см. ниже |
| Конфигурация nginx | рендер модуля 07 и `nginx -t` на nginx.org stable | см. ниже |

Сквозные тесты **переустанавливают 3x-ui и перезаписывают системные файлы**, поэтому запускаются только на одноразовой машине и без `E2E_DISPOSABLE=1` отказываются работать:

```bash
sudo E2E_DISPOSABLE=1 bash tests/e2e/module05.sh fresh      # или upgrade, no-ip-limit
sudo E2E_DISPOSABLE=1 bash tests/nginx/check_config.sh      # нужен nginx >= 1.25.1
```

Инструменты в CI закреплены: actions — по SHA коммита, actionlint и gitleaks — по контрольной сумме архива, ruff — по хешу колеса (`tests/requirements-lint.txt`).

<sub>[↑ К содержанию](#содержание)</sub>
