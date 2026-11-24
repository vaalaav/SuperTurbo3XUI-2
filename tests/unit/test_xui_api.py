"""Модульные тесты lib/xui_api.py: чистая логика и протокол входа в API 3x-ui 3.11.

Запуск: python3 -m unittest discover -s tests/unit -v
Только стандартная библиотека — тестам не нужны сторонние зависимости.
"""

from __future__ import annotations

import copy
import json
import os
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from typing import ClassVar

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import xui_api  # noqa: E402

DOMAIN = "node.example.com"
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

    WARP = {"tag": "warp", "protocol": "wireguard", "settings": {}}
    WARP_RULE = {"type": "field", "outboundTag": "warp", "domain": ["geosite:openai"]}
    GEMINI_UDP_BLOCK = {
        "type": "field",
        "network": "udp",
        "domain": ["geosite:google-deepmind"],
        "outboundTag": "blocked",
    }

    def base(self) -> dict:
        return xui_api.build_base_xray_template(geo_ru_available=True)

    def current_with_ai(self) -> dict:
        cur = self.base()
        cur["outbounds"].append(self.WARP)
        cur["routing"]["rules"][1:1] = [self.WARP_RULE, self.GEMINI_UDP_BLOCK]
        return cur

    def test_keeps_ai_outbound_and_rules_right_after_api_rule(self) -> None:
        merged = xui_api.merge_custom_into_base(self.base(), self.current_with_ai())
        self.assertIn("warp", [o["tag"] for o in merged["outbounds"]])
        rules = merged["routing"]["rules"]
        self.assertEqual(rules[0]["outboundTag"], "api")
        self.assertEqual(rules[1:3], [self.WARP_RULE, self.GEMINI_UDP_BLOCK])

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
