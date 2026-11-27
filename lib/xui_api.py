#!/usr/bin/env python3
"""
Контроллер локального REST API 3x-ui >= 3.11.0.
Создаёт инбаунды и клиента через API панели, чтобы реляционные таблицы
clients / client_inbounds / client_traffics оставались полностью консистентными.
"""
import argparse
import base64
import copy
import http.cookiejar
import json
import os
import secrets
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class XuiApiClient:
    def __init__(self, port: str, base_path: str, username: str, password: str):
        clean_path = base_path.strip("/")
        self.base_url = f"http://127.0.0.1:{port}/{clean_path}" if clean_path else f"http://127.0.0.1:{port}"
        self.username = username
        self.password = password
        self.cj = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cj))
        self.token = None
        self.csrf = None

    def _req(self, method: str, endpoint: str, data=None, form=False, check=True, timeout: float = 20):
        """Запрос к API панели. При check=True ответ {"success": false} считается ошибкой:
        3x-ui отвечает HTTP 200 даже на отклонённые запросы, и без проверки они проходят молча."""
        res = self._raw_req(method, endpoint, data=data, form=form, timeout=timeout)
        if check and isinstance(res, dict) and res.get("success") is False:
            raise RuntimeError(f"API 3x-ui отклонил {method} {endpoint}: {res.get('msg') or res}")
        return res

    def _raw_req(self, method: str, endpoint: str, data=None, form=False, timeout: float = 20):
        url = f"{self.base_url}{endpoint}"
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        elif self.csrf:
            # Сессия по cookie: 3.11 требует X-CSRF-Token на изменяющих запросах, включая /login.
            headers["X-CSRF-Token"] = self.csrf
        body = None
        if data is not None:
            if form:
                body = urllib.parse.urlencode(data).encode("utf-8")
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                body = json.dumps(data).encode("utf-8")
                headers["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with self.opener.open(req, timeout=timeout) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                return json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {e.code} на {method} {endpoint}: {err_body[:300]}") from e
        except urllib.error.URLError as e:
            raise RuntimeError(f"Панель 3x-ui недоступна ({self.base_url}): {e.reason}") from e

    def _fetch_csrf(self) -> str:
        tok = self._raw_req("GET", "/csrf-token").get("obj") or ""
        if not tok:
            raise RuntimeError("Панель не выдала CSRF-токен (/csrf-token).")
        return tok

    def login(self):
        """Авторизация. Основной путь — постоянный API-токен проекта из XUI_API_TOKEN
        (его выпускает ensure_xui_api_token в lib/common.sh). Запасной — логин и пароль панели."""
        token = os.environ.get("XUI_API_TOKEN", "").strip()
        if token:
            self.token = token
            try:
                self.get_settings()
                return True
            except RuntimeError as e:
                if not str(e).startswith("HTTP 401"):
                    raise
                self.token = None
        if not (self.username and self.password):
            raise RuntimeError("Нет рабочего API-токена (XUI_API_TOKEN) и не заданы логин/пароль панели.")
        self.csrf = self._fetch_csrf()
        res = self._req("POST", "/login", {"username": self.username, "password": self.password}, check=False)
        if not res.get("success"):
            raise RuntimeError(f"Не удалось авторизоваться в API 3x-ui: {res.get('msg') or res}")
        self.csrf = self._fetch_csrf()
        return True

    def get_settings(self):
        # В 3.11 эндпоинт только POST; GET отвечает 404 и маскировал бы настоящую ошибку (например 401).
        res = self._req("POST", "/panel/api/setting/all", {})
        if not res.get("success"):
            raise RuntimeError(f"Ошибка чтения настроек 3x-ui: {res}")
        return res.get("obj", {})

    def update_settings(self, settings_obj: dict):
        res = self._req("POST", "/panel/api/setting/update", settings_obj)
        if not res.get("success"):
            raise RuntimeError(f"Ошибка сохранения настроек 3x-ui: {res}")
        return res

    def list_inbounds(self):
        res = self._req("GET", "/panel/api/inbounds/list")
        if not res.get("success"):
            raise RuntimeError(f"Ошибка получения списка инбаундов: {res}")
        return res.get("obj") or []

    def delete_inbound(self, inbound_id: int):
        return self._req("POST", f"/panel/api/inbounds/del/{inbound_id}", {})

    def add_inbound(self, payload: dict):
        res = self._req("POST", "/panel/api/inbounds/add", payload)
        if not res.get("success"):
            raise RuntimeError(f"Ошибка создания инбаунда {payload.get('remark')}: {res}")
        return res.get("obj")

    def get_xray_template(self) -> dict:
        """Шаблон Xray. В 3.11 он не входит в setting/all: читается только через POST /panel/api/xray/."""
        obj = self._req("POST", "/panel/api/xray/", {}).get("obj")
        if isinstance(obj, str):
            obj = json.loads(obj) if obj.strip() else {}
        tpl = obj.get("xraySetting", {}) if isinstance(obj, dict) else {}
        if isinstance(tpl, str):
            tpl = json.loads(tpl) if tpl.strip() else {}
        if not isinstance(tpl, dict) or not tpl:
            raise RuntimeError("Панель вернула пустой шаблон Xray.")
        return tpl

    def get_default_xray_template(self) -> dict:
        """Встроенный шаблон Xray установленной версии панели."""
        obj = self._req("GET", "/panel/api/xray/getDefaultJsonConfig").get("obj")
        if isinstance(obj, str):
            obj = json.loads(obj) if obj.strip() else {}
        if not isinstance(obj, dict) or not obj.get("outbounds"):
            raise RuntimeError("Панель вернула пустой встроенный шаблон Xray.")
        return obj

    def update_geofiles(self):
        """Штатное обновление всех geo-файлов панели (Loyalsoldier, IR, RU): каждый файл сверяется
        с дайджестом своего релиза и заменяется атомарно; Xray перезапускается, только если что-то
        изменилось."""
        return self._req("POST", "/panel/api/server/updateGeofile", {}, timeout=300)

    def validate_geodata(self, tokens: list[str], kind: str) -> list[dict]:
        """Проблемные правила (нет файла или категории) среди tokens; kind — domain или ip."""
        if not tokens:
            return []
        data = {"tokens": ",".join(tokens), "kind": kind}
        return self._req("POST", "/panel/api/xray/geodata/validate", data, form=True).get("obj") or []

    def update_xray_template(self, tpl: dict):
        """Сохраняет шаблон Xray. setting/update поле xrayTemplateConfig молча игнорирует."""
        return self._req("POST", "/panel/api/xray/update", {"xraySetting": json.dumps(tpl, indent=2)}, form=True)

    def list_clients(self):
        return self._req("GET", "/panel/api/clients/list").get("obj") or []

    def delete_client(self, email: str):
        # Эндпоинт принимает email клиента, а не его id.
        return self._req("POST", f"/panel/api/clients/del/{urllib.parse.quote(email, safe='')}", {})

    def add_client(self, client: dict, inbound_ids: list):
        return self._req("POST", "/panel/api/clients/add", {"client": client, "inboundIds": inbound_ids})

    def add_host_group(self, payload: dict):
        res = self._req("POST", "/panel/api/hosts/add", payload)
        if not res.get("obj"):
            raise RuntimeError(f"Хост-группа «{payload.get('remark')}» не создала ни одного хоста: {res}")
        return res["obj"]

    def client_links(self, email: str) -> list:
        return self._req("GET", f"/panel/api/clients/links/{urllib.parse.quote(email, safe='')}").get("obj") or []

    def restart_xray(self):
        # Ошибку не пробрасываем: итог рестарта проверяет wait_xray_running по состоянию Xray,
        # но и молча её не теряем.
        try:
            self._req("POST", "/panel/api/server/restartXrayService", {})
        except RuntimeError as e:
            print(f"Предупреждение: запрос рестарта Xray не прошёл: {e}", file=sys.stderr)

    def wait_xray_running(self, timeout: float = 30.0, settle: float = 3.0, stable_polls: int = 4):
        """Убеждается, что Xray устойчиво работает после рестарта.
        Панель проверяет синтаксис шаблона, но ошибки запуска (например, kernel TUN без прав)
        видны только в /server/status, причём с задержкой ~2 с: сразу после рестарта там ещё
        старое «running». Поэтому ждём settle и требуем несколько подряд «running»."""
        time.sleep(settle)
        deadline = time.monotonic() + timeout
        last, running, errors = {}, 0, 0
        while time.monotonic() < deadline:
            try:
                last = self._req("GET", "/panel/api/server/status").get("obj", {}).get("xray") or {}
            except RuntimeError:
                last = {}
            state = last.get("state")
            running = running + 1 if state == "running" else 0
            errors = errors + 1 if state == "error" else 0
            if running >= stable_polls:
                return
            if errors >= 2:
                break
            time.sleep(1)
        raise RuntimeError(f"Xray не запустился после применения конфигурации: {last.get('errorMsg') or last or 'нет ответа'}")


def detect_country_label(server_ip: str) -> str:
    names_ru = {
        "NL": "Нидерланды", "DE": "Германия", "FI": "Финляндия", "FR": "Франция",
        "SE": "Швеция", "GB": "Великобритания", "PL": "Польша", "EE": "Эстония",
        "LV": "Латвия", "LT": "Литва", "US": "США", "SG": "Сингапур", "JP": "Япония",
        "CH": "Швейцария", "AT": "Австрия", "CZ": "Чехия", "TR": "Турция", "KZ": "Казахстан",
    }
    providers = (
        (f"https://ipinfo.io/{server_ip}/json", lambda d: (d.get("country"), d.get("country"))),
        (
            f"https://ipwho.is/{server_ip}",
            lambda d: (d.get("country_code") if d.get("success") else "", d.get("country")),
        ),
        (
            f"http://ip-api.com/json/{server_ip}?fields=status,country,countryCode",
            lambda d: (d.get("countryCode") if d.get("status") == "success" else "", d.get("country")),
        ),
    )
    for url, extract in providers:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=6) as r:
                d = json.loads(r.read().decode("utf-8"))
                raw_code, raw_name = extract(d)
                code = (raw_code or "").strip().upper()
                if len(code) == 2 and code.isalpha():
                    flag = "".join(chr(0x1F1E6 + ord(ch) - ord("A")) for ch in code)
                    return f"{flag} {names_ru.get(code, raw_name or code)}"
        except Exception:  # noqa: S112, BLE001 — перебор резервных GeoIP-источников; при сбое всех берётся «🌐 Node»
            continue
    return "🌐 Node"


def build_base_xray_template(default_tpl: dict, geo_ru_available: bool = True) -> dict:
    """Базовый шаблон Xray проекта поверх встроенного шаблона установленной версии 3x-ui.

    От встроенного шаблона берутся api (с RoutingService), блок metrics, inbound api (`tunnel`),
    политики, статистика и direct с finalRules — так обновления панели доходят до ноды.
    Сверху проект задаёт DNS через DoH, предпочтение IPv4 для direct и блокировку трафика в РФ.
    """
    tpl = copy.deepcopy(default_tpl)
    ru_domains = [
        "geosite:category-ru",
        "regexp:.*\\.(ru|su|xn--p1ai)$",
    ]
    ru_ips = ["geoip:ru"]
    if geo_ru_available:
        ru_domains.append("ext:geosite_RU.dat:ru-available-only-inside")
        ru_ips.append("ext:geoip_RU.dat:ru")

    tpl["dns"] = {
        "servers": [
            "https+local://1.1.1.1/dns-query",
            "https+local://9.9.9.9/dns-query",
        ],
        "queryStrategy": "UseIPv4",
    }
    direct = next((o for o in tpl.get("outbounds", []) if o.get("tag") == "direct"), None)
    if direct is None:
        raise RuntimeError("Во встроенном шаблоне 3x-ui нет outbound direct.")
    # freedom.domainStrategy в Xray устарел: стратегия задаётся в streamSettings.sockopt.
    direct.get("settings", {}).pop("domainStrategy", None)
    direct.setdefault("streamSettings", {}).setdefault("sockopt", {})["domainStrategy"] = "UseIPv4"

    routing = tpl.setdefault("routing", {})
    # IP-правила (geoip:ru) должны срабатывать и для запросов по домену.
    routing["domainStrategy"] = "IPIfNonMatch"
    routing.setdefault("rules", []).extend([
        {"type": "field", "outboundTag": "blocked", "domain": ru_domains},
        {"type": "field", "outboundTag": "blocked", "ip": ru_ips},
    ])
    return tpl


def template_geodata_tokens(tpl: dict) -> tuple[list[str], list[str]]:
    """Правила маршрутизации шаблона, которые ссылаются на geo-файлы: (domain, ip)."""
    domains: list[str] = []
    ips: list[str] = []
    for rule in tpl.get("routing", {}).get("rules", []):
        domains += [t for t in rule.get("domain") or [] if t.startswith(("geosite:", "ext:"))]
        ips += [t for t in rule.get("ip") or [] if t.startswith(("geoip:", "ext:", "!geoip:"))]
    return sorted(set(domains)), sorted(set(ips))


def check_template_geodata(api: "XuiApiClient", tpl: dict):
    """Проверяет по geo-файлам на диске, что все категории правил существуют.
    Xray с отсутствующей категорией не запускается, а панель такой шаблон сохраняет."""
    domains, ips = template_geodata_tokens(tpl)
    issues = api.validate_geodata(domains, "domain") + api.validate_geodata(ips, "ip")
    if issues:
        found = "; ".join(f"{i.get('token')} ({i.get('reason')})" for i in issues)
        raise RuntimeError(f"Правила маршрутизации ссылаются на отсутствующие geo-данные: {found}")


BASE_OUTBOUND_TAGS = ("direct", "blocked", "api", "IPv4")


def _is_custom_rule(rule: dict) -> bool:
    """Правило, добавленное поверх базового шаблона (AI-маршруты и т.п.), которое надо сохранить."""
    tag = rule.get("outboundTag")
    if tag not in ("api", "blocked", "direct"):
        return True
    # Блок UDP/QUIC для Gemini из AI-модуля ведёт в blocked, но это не базовое правило.
    return tag == "blocked" and rule.get("network") == "udp" and "geosite:google-deepmind" in (rule.get("domain") or [])


def merge_custom_into_base(base: dict, current: dict) -> dict:
    """Базовый шаблон + пользовательские аутбаунды и правила из текущего шаблона.
    Пользовательские правила встают сразу после правила api, как их ставит configure-ai."""
    base_tags = {o.get("tag") for o in base.get("outbounds", [])} | set(BASE_OUTBOUND_TAGS)
    base["outbounds"] += [o for o in current.get("outbounds", []) if o.get("tag") not in base_tags]
    custom = [r for r in current.get("routing", {}).get("rules", []) if _is_custom_rule(r)]
    rules = base.setdefault("routing", {}).setdefault("rules", [])
    at = 1 if rules and rules[0].get("outboundTag") == "api" else 0
    rules[at:at] = custom
    return base


def build_happ_routing_uri(domain: str, geo_path: str = "", use_mirror: bool = False) -> str:
    if use_mirror and geo_path:
        geoip_url = f"https://{domain}/{geo_path.strip('/')}/geoip.dat"
        geosite_url = f"https://{domain}/{geo_path.strip('/')}/geosite.dat"
    else:
        geoip_url = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
        geosite_url = "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"

    profile = {
        "Name": "RU Direct / World Proxy",
        "GlobalProxy": "true",
        "RouteOrder": "block-proxy-direct",
        "DomainStrategy": "IPIfNonMatch",
        "UseChunkFiles": "true",
        "RemoteDNSType": "DoH",
        "RemoteDNSDomain": "https://1.1.1.1/dns-query",
        "RemoteDNSIP": "1.1.1.1",
        "DomesticDNSType": "DoU",
        "DomesticDNSDomain": "77.88.8.8",
        "DomesticDNSIP": "77.88.8.8",
        "Geoipurl": geoip_url,
        "Geositeurl": geosite_url,
        "LastUpdated": "1735689600",
        "DirectSites": [
            "geosite:private",
            "geosite:category-ru",
            "geosite:ru-available-only-inside",
            "domain:ru",
            "domain:su",
            "domain:xn--p1ai",
            "domain:sberbank.ru",
            "domain:gosuslugi.ru",
            "domain:tbank.ru",
            "domain:ozon.ru",
            "domain:wildberries.ru",
        ],
        "DirectIp": [
            "geoip:private",
            "geoip:ru",
        ],
        "ProxySites": [
            "geosite:ru-blocked",
            "geosite:youtube",
            "geosite:discord",
            "geosite:instagram",
            "geosite:meta",
            "geosite:openai",
            "geosite:google-deepmind",
            "geosite:anthropic",
            "geosite:telegram",
        ],
        "ProxyIp": [
            "geoip:ru-blocked",
        ],
        "BlockSites": [
            "geosite:category-ads-all",
        ],
        "BlockIp": [],
    }
    encoded = base64.b64encode(json.dumps(profile, ensure_ascii=False, separators=(",", ":")).encode("utf-8")).decode("ascii")
    return f"happ://routing/onadd/{encoded}"


def verify_client_links(links: list, client_uuid: str, domain: str):
    """Проверяет ссылки, которые панель реально отдаёт клиенту: оба транспорта на домене:443,
    с нашим UUID; Reality — с flow Vision, XHTTP — через TLS и без flow."""
    found = {}
    for link in links:
        u = urllib.parse.urlsplit(link)
        q = dict(urllib.parse.parse_qsl(u.query))
        found[q.get("type")] = (u, q)

    def need(cond, msg):
        if not cond:
            raise RuntimeError(f"Проверка ссылок панели не пройдена: {msg}. Ссылки: {links}")

    for transport, security in (("tcp", "reality"), ("xhttp", "tls")):
        need(transport in found, f"нет ссылки type={transport}")
        u, q = found[transport]
        need(u.username == client_uuid, f"{transport}: UUID {u.username} вместо {client_uuid}")
        need((u.hostname, u.port) == (domain.lower(), 443), f"{transport}: адрес {u.hostname}:{u.port} вместо {domain}:443")
        need(q.get("security") == security, f"{transport}: security={q.get('security')} вместо {security}")
    need(found["tcp"][1].get("flow") == "xtls-rprx-vision", "reality: нет flow xtls-rprx-vision")
    need("flow" not in found["xhttp"][1], "xhttp: в ссылке есть flow")


def cmd_setup_node(args):
    api = XuiApiClient(args.panel_port, args.panel_path, args.panel_user, args.panel_pass)
    api.login()

    settings = api.get_settings()
    geo_ru_exists = os.path.isfile("/usr/local/x-ui/bin/geosite_RU.dat") and os.path.isfile("/usr/local/x-ui/bin/geoip_RU.dat")
    tpl = build_base_xray_template(api.get_default_xray_template(), geo_ru_available=geo_ru_exists)

    settings["webListen"] = "127.0.0.1"
    settings["webCertFile"] = ""
    settings["webKeyFile"] = ""
    settings["subEnable"] = True
    settings["subListen"] = "127.0.0.1"
    settings["subPort"] = int(args.sub_port)
    settings["subPath"] = f"/{args.sub_path.strip('/')}/"
    settings["subCertFile"] = ""
    settings["subKeyFile"] = ""
    settings["subURI"] = f"https://{args.domain}/{args.sub_path.strip('/')}/"
    settings["subUpdates"] = 12

    happ_uri = ""
    if args.enable_happ == "true":
        happ_uri = build_happ_routing_uri(
            args.domain,
            geo_path=args.geo_path,
            use_mirror=(args.enable_geo_mirror == "true"),
        )
        # В 3.11 роутинг Happ задаётся полем subRoutingRules (ключей subHappRouting/happRouting нет).
        settings["subRoutingRules"] = happ_uri
        settings["subEnableRouting"] = True

    api.update_settings(settings)

    # Шаблон Xray сохраняется отдельным эндпоинтом; пользовательские маршруты (AI) переносятся.
    tpl = merge_custom_into_base(tpl, api.get_xray_template())
    check_template_geodata(api, tpl)
    api.update_xray_template(tpl)

    # Сначала удаляем клиентов (по email), затем инбаунды — иначе остаются клиенты-сироты со старым UUID.
    known_emails = {c.get("email") for c in api.list_clients()}
    for email in ("audit_system", "user1", "user1-reality", "user1-xhttp"):
        if email in known_emails:
            api.delete_client(email)

    existing = api.list_inbounds()
    for ib in existing:
        if ib.get("tag") in ("inbound-reality-selfsteal", "inbound-xhttp-packetup") or ib.get("port") in (443, 11443):
            api.delete_inbound(ib["id"])

    loc = detect_country_label(args.server_ip)
    client_uuid = args.client_uuid or str(uuid.uuid4())
    sub_id = args.sub_id or secrets.token_hex(8)
    short_id_1 = args.short_id_1 or secrets.token_hex(4)
    short_id_2 = args.short_id_2 or secrets.token_hex(8)

    # Инбаунд #1: VLESS + TCP/RAW + Reality (Self-Steal на 443 -> Nginx 127.0.0.1:8443)
    reality_settings = {
        "clients": [],
        "decryption": "none",
        "fallbacks": [],
    }
    reality_stream = {
        "network": "tcp",
        "security": "reality",
        "externalProxy": [],
        "realitySettings": {
            "show": False,
            "xver": 1,
            "dest": "127.0.0.1:8443",
            "target": "127.0.0.1:8443",
            "serverNames": [args.domain],
            "privateKey": args.reality_priv,
            "minClientVer": "",
            "maxClientVer": "",
            "maxTimediff": 0,
            "mldsa65Seed": "",
            "shortIds": [short_id_1, short_id_2],
            "settings": {
                "publicKey": args.reality_pub,
                "fingerprint": args.utls_fp,
                "serverName": args.domain,
                "spiderX": "/",
                "mldsa65Verify": "",
            },
        },
        "tcpSettings": {
            "acceptProxyProtocol": False,
            "header": {"type": "none"},
        },
    }
    sniffing = {
        "enabled": True,
        "destOverride": ["http", "tls", "quic"],
        "metadataOnly": False,
        "routeOnly": True,
    }

    api.add_inbound(
        {
            "up": 0,
            "down": 0,
            "total": 0,
            "remark": f"{loc} - Reality",
            "enable": True,
            "expiryTime": 0,
            "listen": "",
            "port": 443,
            "protocol": "vless",
            "tag": "inbound-reality-selfsteal",
            "disableFlow": False,
            "settings": json.dumps(reality_settings),
            "streamSettings": json.dumps(reality_stream),
            "sniffing": json.dumps(sniffing),
        }
    )

    # Инбаунд #2: VLESS + XHTTP Packet-UP за Nginx HTTP/2 (127.0.0.1:11443)
    xhttp_settings_obj = {
        "clients": [],
        "decryption": "none",
        "fallbacks": [],
    }
    xhttp_stream = {
        "network": "xhttp",
        "security": "none",
        "externalProxy": [],
        "xhttpSettings": {
            "host": args.domain,
            "path": f"/{args.xhttp_path}/",
            "mode": "packet-up",
            "noGRPCHeader": True,
            "xPaddingBytes": "200-1500",
            "xPaddingObfsMode": True,
            "xPaddingKey": "sid",
            "xPaddingPlacement": "cookie",
            "xPaddingMethod": "tokenish",
            "scMaxEachPostBytes": 1000000,
            "scMinPostsIntervalMs": "10-50",
            "xmux": {
                "maxConnections": "3",
                "cMaxReuseTimes": "64-128",
                "hMaxRequestTimes": "600-900",
                "hMaxReusableSecs": "600-1200",
                "hKeepAlivePeriod": 0
            }
        },
    }

    api.add_inbound(
        {
            "up": 0,
            "down": 0,
            "total": 0,
            "remark": f"{loc} - XHTTP",
            "enable": True,
            "expiryTime": 0,
            "listen": "127.0.0.1",
            "port": 11443,
            "protocol": "vless",
            "tag": "inbound-xhttp-packetup",
            "disableFlow": True,
            "settings": json.dumps(xhttp_settings_obj),
            "streamSettings": json.dumps(xhttp_stream),
            "sniffing": json.dumps(sniffing),
        }
    )

    ibs = {i.get("tag"): i["id"] for i in api.list_inbounds()}
    rid, xid = ibs["inbound-reality-selfsteal"], ibs["inbound-xhttp-packetup"]
    # Хосты задают публичный адрес в ссылках и подписке. Без них XHTTP рекламируется
    # как loopback-порт 11443 без TLS. В 3.11 адреса передаются массивом hosts, alpn — массивом.
    api.add_host_group({
        "inboundIds": [rid], "remark": f"{loc} - Reality", "hosts": [args.domain],
        "port": 443, "security": "same", "isDisabled": False, "isHidden": False,
    })
    api.add_host_group({
        "inboundIds": [xid], "remark": f"{loc} - XHTTP", "hosts": [args.domain],
        "port": 443, "security": "tls", "sni": args.domain, "fingerprint": args.utls_fp,
        "alpn": ["h2", "http/1.1"], "isDisabled": False, "isHidden": False,
    })
    # UUID клиента VLESS передаётся в поле id; неизвестное поле uuid панель отбрасывает и генерирует свой.
    limit_ip = max(0, int(getattr(args, "limit_ip", "") or 0))
    api.add_client({
        "email": "audit_system", "id": client_uuid, "flow": "xtls-rprx-vision", "subId": sub_id,
        "limitIp": limit_ip, "totalGB": 0, "expiryTime": 0, "enable": True, "tgId": 0,
        "comment": "System audit client", "reset": 0,
    }, [rid, xid])
    api.restart_xray()
    api.wait_xray_running()
    verify_client_links(api.client_links("audit_system"), client_uuid, args.domain)
    print(
        json.dumps(
            {
                "status": "ok",
                "location": loc,
                "client_uuid": client_uuid,
                "sub_id": sub_id,
                "short_id_1": short_id_1,
                "happ_uri": happ_uri,
            }
        )
    )


def cmd_configure_ai(args):
    api = XuiApiClient(args.panel_port, args.panel_path, args.panel_user, args.panel_pass)
    api.login()

    tpl = api.get_xray_template()
    outbounds = tpl.setdefault("outbounds", [])
    rules = tpl.setdefault("routing", {}).setdefault("rules", [])

    # Перед применением снимаются прежние AI-маршруты, включая WARP, удалённый из проекта:
    # на нодах, установленных раньше, он мог остаться в шаблоне.
    outbounds = [o for o in outbounds if o.get("tag") not in ("warp", "psiphon-out")]
    rules = [
        r
        for r in rules
        if r.get("outboundTag") not in ("warp", "psiphon-out")
        and not (
            r.get("outboundTag") == "blocked"
            and r.get("network") == "udp"
            and "geosite:google-deepmind" in (r.get("domain") or [])
        )
    ]

    insert_idx = 1 if rules and rules[0].get("outboundTag") == "api" else 0

    if args.ai_mode == "psiphon":
        # Форма servers[] нужна для TCP-теста исходящих в панели 3x-ui 3.11 (она читает только
        # settings.servers[]), при этом Xray 26+ также корректно работает с servers[].
        # vps-psiphon публикует SOCKS5 на 127.0.0.1 (--bind-loopback). UDP туда не направляется:
        # локальный прокси Psiphon его не поддерживает.
        psiphon_outbound = {
            "tag": "psiphon-out",
            "protocol": "socks",
            "settings": {"servers": [{"address": "127.0.0.1", "port": int(args.psiphon_port)}]},
        }
        outbounds.append(psiphon_outbound)

        gemini_domains = ["geosite:google-deepmind"]
        if args.psiphon_ip_detect == "true":
            gemini_domains.append("geosite:category-ip-geo-detect")

        rules.insert(
            insert_idx,
            {
                "type": "field",
                "network": "udp",
                "domain": ["geosite:google-deepmind"],
                "outboundTag": "blocked",
            },
        )
        insert_idx += 1
        rules.insert(
            insert_idx,
            {
                "type": "field",
                "network": "tcp",
                "domain": gemini_domains,
                "outboundTag": "psiphon-out",
            },
        )

    tpl["outbounds"] = outbounds
    tpl["routing"]["rules"] = rules
    check_template_geodata(api, tpl)
    api.update_xray_template(tpl)
    api.restart_xray()
    api.wait_xray_running()
    applied = [o["tag"] for o in outbounds if o.get("tag") == "psiphon-out"]
    print(json.dumps({"status": "ok", "ai_mode": args.ai_mode, "applied": applied}))


def cmd_update_geo(args):
    """Обновляет geo-файлы штатным механизмом панели и проверяет, что правила текущего шаблона
    по-прежнему находят свои категории в обновлённых файлах."""
    api = XuiApiClient(args.panel_port, args.panel_path, args.panel_user, args.panel_pass)
    api.login()
    res = api.update_geofiles()
    check_template_geodata(api, api.get_xray_template())
    print(json.dumps({"status": "ok", "msg": res.get("msg", "")}, ensure_ascii=False))


def cmd_client_links(args):
    """Печатает ссылки клиента так, как их отдаёт панель (по одной в строке)."""
    api = XuiApiClient(args.panel_port, args.panel_path, args.panel_user, args.panel_pass)
    api.login()
    links = [str(x) for x in api.client_links(args.email) if str(x).startswith("vless://")]
    if not links:
        raise RuntimeError(f"Панель не вернула ссылок для клиента {args.email}")
    print("\n".join(links))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("setup-node")
    for name in (
        "panel-port", "panel-path", "panel-user", "panel-pass",
        "sub-port", "sub-path", "domain", "server-ip",
        "reality-priv", "reality-pub", "utls-fp", "xhttp-path",
        "client-uuid", "sub-id", "short-id-1", "short-id-2",
        "enable-happ", "enable-geo-mirror", "geo-path", "limit-ip",
    ):
        p1.add_argument(f"--{name}", default="")

    p2 = sub.add_parser("configure-ai")
    for name in ("panel-port", "panel-path", "panel-user", "panel-pass", "psiphon-port", "psiphon-ip-detect"):
        p2.add_argument(f"--{name}", default="")
    p2.add_argument("--ai-mode", choices=("none", "psiphon"), default="none")

    p3 = sub.add_parser("update-geo")
    for name in ("panel-port", "panel-path", "panel-user", "panel-pass"):
        p3.add_argument(f"--{name}", default="")

    p4 = sub.add_parser("client-links")
    for name in ("panel-port", "panel-path", "panel-user", "panel-pass"):
        p4.add_argument(f"--{name}", default="")
    p4.add_argument("--email", default="audit_system")

    args = parser.parse_args()
    if args.cmd == "client-links":
        cmd_client_links(args)
    elif args.cmd == "setup-node":
        cmd_setup_node(args)
    elif args.cmd == "configure-ai":
        cmd_configure_ai(args)
    elif args.cmd == "update-geo":
        cmd_update_geo(args)


if __name__ == "__main__":
    main()
