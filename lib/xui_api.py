#!/usr/bin/env python3
"""
Контроллер локального REST API 3x-ui >= 3.11.0.
Создаёт инбаунды и клиента через API панели, чтобы реляционные таблицы
clients / client_inbounds / client_traffics оставались полностью консистентными.
"""
import argparse
import base64
import http.cookiejar
import json
import os
import secrets
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

    def _req(self, method: str, endpoint: str, data=None, form=False):
        url = f"{self.base_url}{endpoint}"
        headers = {"Accept": "application/json"}
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
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
            with self.opener.open(req, timeout=20) as resp:
                raw = resp.read().decode("utf-8", errors="replace")
                return json.loads(raw) if raw.strip() else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {e.code} on {endpoint}: {err_body}") from e

    def login(self):
        res = self._req("POST", "/login", {"username": self.username, "password": self.password}, form=True)
        if not res.get("success"):
            raise RuntimeError(f"Не удалось авторизоваться в API 3x-ui: {res}")
        return True

    def get_settings(self):
        res = self._req("POST", "/panel/setting/all", {})
        if not res.get("success"):
            raise RuntimeError(f"Ошибка чтения настроек 3x-ui: {res}")
        return res.get("obj", {})

    def update_settings(self, settings_obj: dict):
        res = self._req("POST", "/panel/setting/update", settings_obj)
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

    def restart_xray(self):
        try:
            self._req("POST", "/panel/api/server/restartXrayService", {})
        except Exception:
            pass


def detect_country_label(server_ip: str) -> str:
    names_ru = {
        "NL": "Нидерланды", "DE": "Германия", "FI": "Финляндия", "FR": "Франция",
        "SE": "Швеция", "GB": "Великобритания", "PL": "Польша", "EE": "Эстония",
        "LV": "Латвия", "LT": "Литва", "US": "США", "SG": "Сингапур", "JP": "Япония",
        "CH": "Швейцария", "AT": "Австрия", "CZ": "Чехия", "TR": "Турция", "KZ": "Казахстан",
    }
    try:
        req = urllib.request.Request(
            f"http://ip-api.com/json/{server_ip}?fields=status,country,countryCode",
            headers={"User-Agent": "Mozilla/5.0"},
        )
        with urllib.request.urlopen(req, timeout=6) as r:
            d = json.loads(r.read().decode("utf-8"))
            if d.get("status") == "success":
                code = (d.get("countryCode") or "").upper()
                if len(code) == 2 and code.isalpha():
                    flag = "".join(chr(0x1F1E6 + ord(ch) - ord("A")) for ch in code)
                    return f"{flag} {names_ru.get(code, d.get('country', code))}"
    except Exception:
        pass
    return "🌐 Node"


def build_base_xray_template(geo_ru_available: bool = True) -> dict:
    ru_domains = [
        "geosite:category-ru",
        "regexp:.*\\.(ru|su|xn--p1ai)$",
    ]
    ru_ips = ["geoip:ru"]
    if geo_ru_available:
        ru_domains.append("ext:geosite_RU.dat:ru-available-only-inside")
        ru_ips.append("ext:geoip_RU.dat:ru")

    return {
        "log": {
            "access": "none",
            "dnsLog": False,
            "error": "",
            "loglevel": "warning",
            "maskAddress": "",
        },
        "api": {
            "tag": "api",
            "services": ["HandlerService", "LoggerService", "StatsService"],
        },
        "dns": {
            "servers": [
                "https+local://1.1.1.1/dns-query",
                "https+local://9.9.9.9/dns-query",
            ],
            "queryStrategy": "UseIPv4",
        },
        "inbounds": [
            {
                "listen": "127.0.0.1",
                "port": 62789,
                "protocol": "dokodemo-door",
                "settings": {"address": "127.0.0.1"},
                "tag": "api",
            }
        ],
        "outbounds": [
            {
                "tag": "direct",
                "protocol": "freedom",
                "settings": {"domainStrategy": "UseIPv4"},
            },
            {
                "tag": "blocked",
                "protocol": "blackhole",
                "settings": {},
            },
        ],
        "policy": {
            "levels": {"0": {"statsUserDownlink": True, "statsUserUplink": True}},
            "system": {"statsInboundDownlink": True, "statsInboundUplink": True},
        },
        "routing": {
            "domainStrategy": "IPIfNonMatch",
            "rules": [
                {
                    "type": "field",
                    "inboundTag": ["api"],
                    "outboundTag": "api",
                },
                {
                    "type": "field",
                    "outboundTag": "blocked",
                    "protocol": ["bittorrent"],
                },
                {
                    "type": "field",
                    "outboundTag": "blocked",
                    "ip": ["geoip:private"],
                },
                {
                    "type": "field",
                    "outboundTag": "blocked",
                    "domain": ru_domains,
                },
                {
                    "type": "field",
                    "outboundTag": "blocked",
                    "ip": ru_ips,
                },
            ],
        },
        "stats": {},
    }


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


def cmd_setup_node(args):
    api = XuiApiClient(args.panel_port, args.panel_path, args.panel_user, args.panel_pass)
    api.login()

    settings = api.get_settings()
    geo_ru_exists = os.path.isfile("/usr/local/x-ui/bin/geosite_RU.dat") and os.path.isfile("/usr/local/x-ui/bin/geoip_RU.dat")
    tpl = build_base_xray_template(geo_ru_available=geo_ru_exists)

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
    settings["subShowInfo"] = True
    settings["subUpdates"] = 12
    settings["xrayTemplateConfig"] = json.dumps(tpl, indent=2)

    happ_uri = ""
    if args.enable_happ == "true":
        happ_uri = build_happ_routing_uri(
            args.domain,
            geo_path=args.geo_path,
            use_mirror=(args.enable_geo_mirror == "true"),
        )
        # Включаем только Happ Routing; Incy Routing остаётся пустым/выключенным
        settings["subHappRouting"] = happ_uri
        if "happRouting" in settings:
            settings["happRouting"] = happ_uri
        if "subIncyRouting" in settings:
            settings["subIncyRouting"] = ""

    api.update_settings(settings)

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
        "clients": [
            {
                "id": client_uuid,
                "flow": "xtls-rprx-vision",
                "email": "user1-reality",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "enable": True,
                "tgId": 0,
                "subId": sub_id,
                "comment": "Primary Reality client",
                "reset": 0,
            }
        ],
        "decryption": "none",
        "fallbacks": [],
    }
    reality_stream = {
        "network": "tcp",
        "security": "reality",
        "externalProxy": [
            {
                "forceTls": "same",
                "dest": args.domain,
                "port": 443,
                "remark": "",
            }
        ],
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
            "settings": json.dumps(reality_settings),
            "streamSettings": json.dumps(reality_stream),
            "sniffing": json.dumps(sniffing),
        }
    )

    # Инбаунд #2: VLESS + XHTTP Packet-UP за Nginx HTTP/2 (127.0.0.1:11443)
    xhttp_settings_obj = {
        "clients": [
            {
                "id": client_uuid,
                "flow": "",
                "email": "user1-xhttp",
                "limitIp": 0,
                "totalGB": 0,
                "expiryTime": 0,
                "enable": True,
                "tgId": 0,
                "subId": sub_id,
                "comment": "Primary XHTTP client",
                "reset": 0,
            }
        ],
        "decryption": "none",
        "fallbacks": [],
    }
    xhttp_stream = {
        "network": "xhttp",
        "security": "none",
        "externalProxy": [
            {
                "forceTls": "tls",
                "dest": args.domain,
                "port": 443,
                "remark": "",
            }
        ],
        "xhttpSettings": {
            "path": f"/{args.xhttp_path.strip('/')}/",
            "host": args.domain,
            "mode": "packet-up",
            "noGRPCHeader": True,
            "noSSEHeader": False,
            "xPaddingBytes": "200-1500",
            "xPaddingObfsMode": True,
            "xPaddingKey": "sid",
            "xPaddingPlacement": "cookie",
            "xPaddingMethod": "tokenish",
            "scMaxEachPostBytes": "500000-1000000",
            "scMinPostsIntervalMs": "10-50",
            "scMaxBufferedPosts": 30,
            "scStreamUpServerSecs": "20-80",
            "xmux": {
                "maxConcurrency": "",
                "maxConnections": "3",
                "cMaxReuseTimes": "64-128",
                "hMaxRequestTimes": "600-900",
                "hMaxReusableSecs": "600-1200",
                "hKeepAlivePeriod": 0,
            },
            "headers": {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/145.0.0.0 Safari/537.36",
                "Accept-Language": "ru-RU,ru;q=0.9,en-US;q=0.8,en;q=0.7",
            },
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
            "settings": json.dumps(xhttp_settings_obj),
            "streamSettings": json.dumps(xhttp_stream),
            "sniffing": json.dumps(sniffing),
        }
    )

    api.restart_xray()
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

    settings = api.get_settings()
    tpl = json.loads(settings.get("xrayTemplateConfig") or "{}")
    outbounds = tpl.setdefault("outbounds", [])
    rules = tpl.setdefault("routing", {}).setdefault("rules", [])

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

    if args.ai_mode in ("warp", "combo") and args.warp_priv_key:
        warp_outbound = {
            "tag": "warp",
            "protocol": "wireguard",
            "settings": {
                "secretKey": args.warp_priv_key,
                "address": [args.warp_v4, args.warp_v6],
                "peers": [
                    {
                        "publicKey": args.warp_peer_pub,
                        "endpoint": "engage.cloudflareclient.com:2408",
                    }
                ],
                "reserved": [int(x) for x in args.warp_reserved.split(",") if x.strip()],
                "mtu": 1280,
                "kernelMode": False,
            },
        }
        outbounds.append(warp_outbound)

        warp_domains = ["geosite:openai", "geosite:anthropic", "geosite:netflix", "geosite:meta"]
        if args.ai_mode == "warp":
            warp_domains.append("geosite:google-deepmind")
        rules.insert(
            insert_idx,
            {
                "type": "field",
                "outboundTag": "warp",
                "domain": warp_domains,
            },
        )
        insert_idx += 1

    if args.ai_mode in ("psiphon", "combo"):
        psiphon_outbound = {
            "tag": "psiphon-out",
            "protocol": "socks",
            "settings": {
                "servers": [
                    {
                        "address": "127.0.0.1",
                        "port": int(args.psiphon_port),
                    }
                ]
            },
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
    settings["xrayTemplateConfig"] = json.dumps(tpl, indent=2)
    api.update_settings(settings)
    api.restart_xray()
    print(json.dumps({"status": "ok", "ai_mode": args.ai_mode}))


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("setup-node")
    for name in (
        "panel-port", "panel-path", "panel-user", "panel-pass",
        "sub-port", "sub-path", "domain", "server-ip",
        "reality-priv", "reality-pub", "utls-fp", "xhttp-path",
        "client-uuid", "sub-id", "short-id-1", "short-id-2",
        "enable-happ", "enable-geo-mirror", "geo-path",
    ):
        p1.add_argument(f"--{name}", default="")

    p2 = sub.add_parser("configure-ai")
    for name in (
        "panel-port", "panel-path", "panel-user", "panel-pass",
        "ai-mode", "warp-priv-key", "warp-peer-pub", "warp-v4", "warp-v6",
        "warp-reserved", "psiphon-port", "psiphon-ip-detect",
    ):
        p2.add_argument(f"--{name}", default="")

    args = parser.parse_args()
    if args.cmd == "setup-node":
        cmd_setup_node(args)
    elif args.cmd == "configure-ai":
        cmd_configure_ai(args)


if __name__ == "__main__":
    main()
