"""Модульные тесты lib/xui_api.py: чистая логика и протокол входа в API 3x-ui 3.11.

Запуск: python3 -m unittest discover -s tests/unit -v
Только стандартная библиотека — тестам не нужны сторонние зависимости.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import io
import json
import os
import sys
import threading
import unittest
import urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import ClassVar
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import xui_api  # noqa: E402

DOMAIN = "node.example.com"
# Встроенный шаблон Xray панели 3x-ui v3.11.0 (internal/web/service/config.json).
DEFAULT_TPL = json.loads((Path(__file__).parent / "fixtures" / "xray_default_3.11.0.json").read_text(encoding="utf-8"))
UUID = "11111111-2222-4333-8444-555555555555"


def link(uuid: str = UUID, host: str = DOMAIN, port: int = 443, **query: str) -> str:
    q = "&".join(f"{k}={v}" for k, v in query.items())
    return f"vless://{uuid}@{host}:{port}?{q}#x"


GOOD_REALITY = link(type="tcp", security="reality", flow="xtls-rprx-vision", sni=DOMAIN)
GOOD_XHTTP = link(type="xhttp", security="tls", sni=DOMAIN, path="%2Fxh%2F")


class VerifyClientLinksTest(unittest.TestCase):
    """Проверка ссылок, которые панель реально отдаёт клиенту."""

    def test_accepts_reality_and_xhttp_on_domain_443(self) -> None:
        xui_api.verify_client_links([GOOD_REALITY, GOOD_XHTTP], UUID, DOMAIN)

    def test_rejects_xhttp_advertised_as_loopback_port_without_tls(self) -> None:
        # Ошибка этапа 1: без хостов панель рекламировала XHTTP как :11443 с security=none.
        broken = link(port=11443, type="xhttp", security="none")
        with self.assertRaisesRegex(RuntimeError, "xhttp: адрес"):
            xui_api.verify_client_links([GOOD_REALITY, broken], UUID, DOMAIN)

    def test_rejects_uuid_generated_by_panel(self) -> None:
        # Ошибка этапа 1: поле uuid отбрасывалось, и панель выдавала свой UUID.
        other = link(
            uuid="807b92ce-9b9d-4ed3-9ffc-586266365b8c", type="tcp", security="reality", flow="xtls-rprx-vision"
        )
        with self.assertRaisesRegex(RuntimeError, "tcp: UUID 807b92ce"):
            xui_api.verify_client_links([other, GOOD_XHTTP], UUID, DOMAIN)

    def test_rejects_flow_on_xhttp(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "xhttp: в ссылке есть flow"):
            xui_api.verify_client_links(
                [GOOD_REALITY, link(type="xhttp", security="tls", flow="xtls-rprx-vision")], UUID, DOMAIN
            )

    def test_rejects_reality_without_vision_flow(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "reality: нет flow"):
            xui_api.verify_client_links([link(type="tcp", security="reality"), GOOD_XHTTP], UUID, DOMAIN)

    def test_rejects_missing_transport(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "нет ссылки type=xhttp"):
            xui_api.verify_client_links([GOOD_REALITY], UUID, DOMAIN)


class MergeCustomIntoBaseTest(unittest.TestCase):
    """Перенос пользовательских маршрутов (AI-модуль) в свежий базовый шаблон."""

    PSIPHON = {"tag": "psiphon-out", "protocol": "socks", "settings": {"address": "127.0.0.1", "port": 1080}}
    PSIPHON_RULE = {
        "type": "field",
        "network": "tcp",
        "outboundTag": "psiphon-out",
        "domain": ["geosite:google-deepmind"],
    }
    GEMINI_UDP_BLOCK = {
        "type": "field",
        "network": "udp",
        "domain": ["geosite:google-deepmind"],
        "outboundTag": "blocked",
    }

    def base(self) -> dict:
        return xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=True)

    def current_with_ai(self) -> dict:
        cur = self.base()
        cur["outbounds"].append(self.PSIPHON)
        cur["routing"]["rules"][1:1] = [self.GEMINI_UDP_BLOCK, self.PSIPHON_RULE]
        return cur

    def test_keeps_ai_outbound_and_rules_right_after_api_rule(self) -> None:
        merged = xui_api.merge_custom_into_base(self.base(), self.current_with_ai())
        self.assertIn("psiphon-out", [o["tag"] for o in merged["outbounds"]])
        rules = merged["routing"]["rules"]
        self.assertEqual(rules[0]["outboundTag"], "api")
        self.assertEqual(rules[1:3], [self.GEMINI_UDP_BLOCK, self.PSIPHON_RULE])

    def test_repeated_merge_is_idempotent(self) -> None:
        # Повторный запуск модуля 05 не должен дублировать ни базовые, ни пользовательские правила.
        once = xui_api.merge_custom_into_base(self.base(), self.current_with_ai())
        twice = xui_api.merge_custom_into_base(self.base(), copy.deepcopy(once))
        self.assertEqual(once, twice)

    def test_drops_stale_base_rules_from_current_template(self) -> None:
        cur = self.base()
        cur["routing"]["rules"].append({"type": "field", "outboundTag": "blocked", "ip": ["1.2.3.4"]})
        merged = xui_api.merge_custom_into_base(self.base(), cur)
        self.assertEqual(merged, self.base())


class BuildBaseTemplateTest(unittest.TestCase):
    """Базовый шаблон проекта строится поверх встроенного шаблона установленной панели."""

    def test_keeps_builtin_parts_of_installed_panel(self) -> None:
        tpl = xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=True)
        # Раньше шаблон собирался с нуля: терялись RoutingService, metrics, inbound tunnel.
        self.assertIn("RoutingService", tpl["api"]["services"])
        self.assertEqual(tpl["metrics"], DEFAULT_TPL["metrics"])
        self.assertEqual(tpl["inbounds"], DEFAULT_TPL["inbounds"])
        self.assertEqual(tpl["policy"], DEFAULT_TPL["policy"])

    def test_direct_prefers_ipv4_via_sockopt_not_deprecated_freedom_key(self) -> None:
        tpl = xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=True)
        direct = next(o for o in tpl["outbounds"] if o["tag"] == "direct")
        self.assertNotIn("domainStrategy", direct["settings"])
        self.assertEqual(direct["streamSettings"]["sockopt"]["domainStrategy"], "UseIPv4")
        self.assertEqual(direct["settings"]["finalRules"], DEFAULT_TPL["outbounds"][0]["settings"]["finalRules"])

    def test_appends_ru_block_rules_after_builtin_rules(self) -> None:
        tpl = xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=True)
        rules = tpl["routing"]["rules"]
        self.assertEqual(rules[: len(DEFAULT_TPL["routing"]["rules"])], DEFAULT_TPL["routing"]["rules"])
        self.assertIn("ext:geosite_RU.dat:ru-available-only-inside", rules[-2]["domain"])
        self.assertEqual(rules[-1]["ip"], ["geoip:ru", "ext:geoip_RU.dat:ru"])
        self.assertEqual(tpl["routing"]["domainStrategy"], "IPIfNonMatch")

    def test_without_ru_geofiles_uses_only_builtin_categories(self) -> None:
        tpl = xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=False)
        domains, ips = xui_api.template_geodata_tokens(tpl)
        self.assertFalse([t for t in domains + ips if t.startswith("ext:")])

    def test_does_not_modify_default_template(self) -> None:
        before = copy.deepcopy(DEFAULT_TPL)
        xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=True)
        self.assertEqual(DEFAULT_TPL, before)

    def test_geodata_tokens_skip_rules_without_geo_files(self) -> None:
        tpl = xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=True)
        domains, ips = xui_api.template_geodata_tokens(tpl)
        self.assertEqual(domains, ["ext:geosite_RU.dat:ru-available-only-inside", "geosite:category-ru"])
        self.assertEqual(ips, ["ext:geoip_RU.dat:ru", "geoip:private", "geoip:ru"])


class FakeXrayPanel(BaseHTTPRequestHandler):
    """Панель для configure-ai: хранит шаблон Xray, проверяет geo-правила по списку известных
    категорий (как /panel/api/xray/geodata/validate), отвечает состоянием Xray."""

    template: ClassVar[dict] = {}
    known: ClassVar[set[str]] = set()
    links: ClassVar[list[str]] = []

    def log_message(self, *args: object) -> None:
        pass

    def _send(self, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/p/panel/api/server/status":
            return self._send({"success": True, "obj": {"xray": {"state": "running"}}})
        if self.path == "/p/panel/api/clients/links/user1":
            return self._send({"success": True, "obj": self.links})
        self._send({"success": False, "msg": "404"})

    def do_POST(self) -> None:
        raw = self.rfile.read(int(self.headers.get("Content-Length") or 0)).decode()
        form = dict(urllib.parse.parse_qsl(raw))
        if self.path == "/p/panel/api/setting/all":
            return self._send({"success": True, "obj": {}})
        if self.path == "/p/panel/api/xray/":
            return self._send({"success": True, "obj": json.dumps({"xraySetting": self.template})})
        if self.path == "/p/panel/api/xray/update":
            type(self).template = json.loads(form["xraySetting"])
            return self._send({"success": True})
        if self.path == "/p/panel/api/xray/geodata/validate":
            issues = [
                {"token": t, "reason": "categoryMissing"} for t in form["tokens"].split(",") if t not in self.known
            ]
            return self._send({"success": True, "obj": issues})
        if self.path == "/p/panel/api/server/restartXrayService":
            return self._send({"success": True})
        self._send({"success": False, "msg": "404"})


class ConfigureAiPsiphonTest(unittest.TestCase):
    """configure-ai для Psiphon: форма аутбаунда, маршруты Gemini, отказ при неизвестных категориях."""

    server: ClassVar[HTTPServer]

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), FakeXrayPanel)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def setUp(self) -> None:
        FakeXrayPanel.template = xui_api.build_base_xray_template(DEFAULT_TPL, geo_ru_available=True)
        domains, ips = xui_api.template_geodata_tokens(FakeXrayPanel.template)
        FakeXrayPanel.known = set(domains + ips) | {"geosite:google-deepmind", "geosite:category-ip-geo-detect"}
        self._env = os.environ.get("XUI_API_TOKEN")
        os.environ["XUI_API_TOKEN"] = "t"
        self._sleep = xui_api.time.sleep
        xui_api.time.sleep = lambda _s: None  # wait_xray_running без реальных пауз

    def tearDown(self) -> None:
        xui_api.time.sleep = self._sleep
        if self._env is None:
            os.environ.pop("XUI_API_TOKEN", None)
        else:
            os.environ["XUI_API_TOKEN"] = self._env

    def run_configure(self, mode: str, ip_detect: str = "false") -> dict:
        args = argparse.Namespace(
            panel_port=str(self.server.server_port),
            panel_path="p",
            panel_user="",
            panel_pass="",
            ai_mode=mode,
            psiphon_port="1080",
            psiphon_ip_detect=ip_detect,
        )
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            xui_api.cmd_configure_ai(args)
        return json.loads(out.getvalue())

    def test_psiphon_outbound_uses_current_socks_form_on_loopback(self) -> None:
        res = self.run_configure("psiphon")
        self.assertEqual(res["applied"], ["psiphon-out"])
        out = next(o for o in FakeXrayPanel.template["outbounds"] if o["tag"] == "psiphon-out")
        # Форма с массивом servers — наследие V2Ray, убранное из документации Xray.
        self.assertEqual(out["settings"], {"address": "127.0.0.1", "port": 1080})

    def test_gemini_tcp_goes_to_psiphon_and_udp_is_blocked_right_after_api(self) -> None:
        self.run_configure("psiphon", ip_detect="true")
        rules = FakeXrayPanel.template["routing"]["rules"]
        self.assertEqual(rules[0]["outboundTag"], "api")
        self.assertEqual(
            rules[1],
            {"type": "field", "network": "udp", "domain": ["geosite:google-deepmind"], "outboundTag": "blocked"},
        )
        self.assertEqual(rules[2]["outboundTag"], "psiphon-out")
        self.assertEqual(rules[2]["network"], "tcp")
        self.assertEqual(rules[2]["domain"], ["geosite:google-deepmind", "geosite:category-ip-geo-detect"])

    def test_mode_none_removes_previous_psiphon_routes(self) -> None:
        # Так модуль 06 снимает маршруты, если туннель перестал подниматься.
        self.run_configure("psiphon")
        res = self.run_configure("none")
        self.assertEqual(res["applied"], [])
        self.assertFalse([o for o in FakeXrayPanel.template["outbounds"] if o["tag"] == "psiphon-out"])
        self.assertFalse(
            [
                r
                for r in FakeXrayPanel.template["routing"]["rules"]
                if "geosite:google-deepmind" in (r.get("domain") or [])
            ]
        )

    def test_leftover_warp_routes_from_older_installs_are_removed(self) -> None:
        # WARP удалён из проекта; на нодах, установленных раньше, его аутбаунд и правило остались в шаблоне.
        FakeXrayPanel.template["outbounds"].append({"tag": "warp", "protocol": "wireguard", "settings": {}})
        FakeXrayPanel.template["routing"]["rules"].insert(
            1, {"type": "field", "outboundTag": "warp", "domain": ["geosite:openai"]}
        )
        for mode in ("none", "psiphon"):
            with self.subTest(mode=mode):
                self.run_configure(mode)
                tpl = FakeXrayPanel.template
                self.assertFalse([o for o in tpl["outbounds"] if o["tag"] == "warp"])
                self.assertFalse([r for r in tpl["routing"]["rules"] if r.get("outboundTag") == "warp"])

    def test_removed_modes_are_rejected(self) -> None:
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            orig = sys.argv
            try:
                sys.argv = ["xui_api.py", "configure-ai", "--ai-mode=warp"]
                xui_api.main()
            finally:
                sys.argv = orig

    def test_unknown_geodata_category_is_rejected_before_saving(self) -> None:
        FakeXrayPanel.known.discard("geosite:google-deepmind")
        before = copy.deepcopy(FakeXrayPanel.template)
        with self.assertRaisesRegex(RuntimeError, "geosite:google-deepmind"):
            self.run_configure("psiphon")
        self.assertEqual(FakeXrayPanel.template, before)


class ClientLinksTest(unittest.TestCase):
    """client-links: ссылки для файла учётных данных и `my3xui audit` берутся у панели как есть."""

    server: ClassVar[HTTPServer]

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), FakeXrayPanel)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def run_links(self) -> str:
        args = argparse.Namespace(
            panel_port=str(self.server.server_port), panel_path="p", panel_user="", panel_pass="", email="user1"
        )
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"XUI_API_TOKEN": "t"}), contextlib.redirect_stdout(out):
            xui_api.cmd_client_links(args)
        return out.getvalue()

    def test_prints_panel_links_one_per_line(self) -> None:
        FakeXrayPanel.links = [GOOD_REALITY, GOOD_XHTTP]
        self.assertEqual(self.run_links().splitlines(), [GOOD_REALITY, GOOD_XHTTP])

    def test_no_links_is_an_error(self) -> None:
        FakeXrayPanel.links = []
        with self.assertRaisesRegex(RuntimeError, "не вернула ссылок"):
            self.run_links()


class FakePanel(BaseHTTPRequestHandler):
    """Минимальная панель с поведением 3x-ui 3.11, наблюдённым на реальной v3.11.0:
    неверный Bearer → 401; /panel/api/setting/all только POST (GET → 404);
    изменяющие запросы с cookie-сессией без X-CSRF-Token → 403, включая /login."""

    TOKEN = "good-token"
    CSRF = "csrf-123"
    seen: ClassVar[list[str]] = []

    def log_message(self, *args: object) -> None:  # тише в выводе тестов
        pass

    def _send(self, code: int, obj: dict | None = None, cookie: str | None = None) -> None:
        body = json.dumps(obj or {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        if cookie:
            self.send_header("Set-Cookie", cookie)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _session(self) -> bool:
        return "sess=1" in (self.headers.get("Cookie") or "")

    def do_GET(self) -> None:
        self.seen.append(f"GET {self.path}")
        if self.path == "/p/csrf-token":
            return self._send(200, {"success": True, "obj": self.CSRF}, cookie="sess=1; Path=/")
        return self._send(404)

    def do_POST(self) -> None:
        self.seen.append(f"POST {self.path}")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        auth = self.headers.get("Authorization") or ""
        if self.path == "/p/login":
            if self.headers.get("X-CSRF-Token") != self.CSRF:
                return self._send(403)
            ok = json.loads(body or b"{}").get("password") == "-pw"
            return self._send(
                200,
                {"success": ok, "msg": "" if ok else "Invalid username or password"},
                cookie="sess=1; Path=/" if ok else None,
            )
        if self.path == "/p/panel/api/setting/all":
            if auth:
                if auth != f"Bearer {self.TOKEN}":
                    return self._send(401)
            elif not (self._session() and self.headers.get("X-CSRF-Token") == self.CSRF):
                return self._send(403)
            return self._send(200, {"success": True, "obj": {"subPort": 1}})
        if self.path == "/p/panel/api/rejected":
            return self._send(200, {"success": False, "msg": "отклонено"})
        return self._send(404)


class LoginProtocolTest(unittest.TestCase):
    """Вход в API: постоянный токен, переход на пароль при 401, проверка success:false."""

    server: ClassVar[HTTPServer]

    @classmethod
    def setUpClass(cls) -> None:
        cls.server = HTTPServer(("127.0.0.1", 0), FakePanel)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def setUp(self) -> None:
        FakePanel.seen.clear()
        self._env = os.environ.pop("XUI_API_TOKEN", None)

    def tearDown(self) -> None:
        os.environ.pop("XUI_API_TOKEN", None)
        if self._env is not None:
            os.environ["XUI_API_TOKEN"] = self._env

    def client(self, password: str = "-pw") -> xui_api.XuiApiClient:
        return xui_api.XuiApiClient(str(self.server.server_port), "p", "admin", password)

    def test_valid_token_is_used_without_csrf_or_password(self) -> None:
        os.environ["XUI_API_TOKEN"] = FakePanel.TOKEN
        api = self.client(password="")
        api.login()
        self.assertEqual(FakePanel.seen, ["POST /p/panel/api/setting/all"])

    def test_rejected_token_falls_back_to_password_login(self) -> None:
        # Регрессия этапа 2: на 401 get_settings повторял запрос GET-ом, получал 404,
        # и переход на вход по паролю не срабатывал.
        os.environ["XUI_API_TOKEN"] = "stale-token"
        api = self.client()
        api.login()
        self.assertIsNone(api.token)
        self.assertEqual(api.get_settings(), {"subPort": 1})
        self.assertNotIn("GET /p/panel/api/setting/all", FakePanel.seen)

    def test_rejected_token_without_password_fails_clearly(self) -> None:
        os.environ["XUI_API_TOKEN"] = "stale-token"
        with self.assertRaisesRegex(RuntimeError, "Нет рабочего API-токена"):
            self.client(password="").login()

    def test_wrong_password_is_reported(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "Invalid username or password"):
            self.client(password="wrong").login()

    def test_success_false_with_http_200_raises(self) -> None:
        os.environ["XUI_API_TOKEN"] = FakePanel.TOKEN
        api = self.client()
        api.login()
        with self.assertRaisesRegex(RuntimeError, "отклонил POST /panel/api/rejected: отклонено"):
            api._req("POST", "/panel/api/rejected", {})


class ArgumentFormTest(unittest.TestCase):
    """Значения, начинающиеся с «-» (ключ Reality, пароль), должны доходить до команды как есть."""

    def test_values_starting_with_dash_are_parsed_in_equals_form(self) -> None:
        got: dict[str, str] = {}
        orig_setup, orig_argv = xui_api.cmd_setup_node, sys.argv
        xui_api.cmd_setup_node = lambda a: got.update(priv=a.reality_priv, pw=a.panel_pass)
        try:
            sys.argv = ["xui_api.py", "setup-node", "--reality-priv=-KgC_4cm", "--panel-pass=-Kq7!x#"]
            xui_api.main()
        finally:
            xui_api.cmd_setup_node, sys.argv = orig_setup, orig_argv
        self.assertEqual(got, {"priv": "-KgC_4cm", "pw": "-Kq7!x#"})


if __name__ == "__main__":
    unittest.main()
