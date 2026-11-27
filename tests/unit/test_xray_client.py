"""Модульные тесты lib/xray_client.py: клиентский конфиг Xray из ссылок, которые отдаёт панель 3x-ui.

Запуск: python3 -m unittest discover -s tests/unit -v
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import shutil
import ssl
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import xray_client  # noqa: E402

UUID = "11111111-2222-4333-8444-555555555555"
DOMAIN = "node.example.com"
PBK = "-Xb2Qm7e1nGq0p9u0r3tXlW8yZ6c4v5b1n2m3k4j5h4"


def link(**query: str) -> str:
    return f"vless://{UUID}@{DOMAIN}:443?{urllib.parse.urlencode(query)}#audit_system"


REALITY = link(
    type="tcp",
    security="reality",
    encryption="none",
    flow="xtls-rprx-vision",
    sni=DOMAIN,
    fp="chrome",
    pbk=PBK,
    sid="a1b2",
    spx="/",
)
XHTTP = link(
    type="xhttp",
    security="tls",
    encryption="none",
    sni=DOMAIN,
    fp="chrome",
    alpn="h2,http/1.1",
    host=DOMAIN,
    path="/api/v2/a1b2c3d4e5f6",
    mode="auto",
    extra=json.dumps({"xPaddingBytes": "100-1000"}),
)


class BuildClientConfigTest(unittest.TestCase):
    def outbound(self, cfg: dict) -> dict:
        return cfg["outbounds"][0]

    def test_reality_vision(self) -> None:
        cfg = xray_client.build_client_config(REALITY, 10808)
        out = self.outbound(cfg)
        user = out["settings"]["vnext"][0]["users"][0]
        self.assertEqual(user, {"id": UUID, "encryption": "none", "flow": "xtls-rprx-vision"})
        self.assertEqual(out["settings"]["vnext"][0]["address"], DOMAIN)
        self.assertEqual(out["settings"]["vnext"][0]["port"], 443)
        st = out["streamSettings"]
        self.assertEqual((st["network"], st["security"]), ("tcp", "reality"))
        # Ключ Reality может начинаться с «-» — он должен пройти без искажений.
        self.assertEqual(st["realitySettings"]["publicKey"], PBK)
        self.assertEqual(st["realitySettings"]["shortId"], "a1b2")
        self.assertEqual(st["realitySettings"]["serverName"], DOMAIN)
        self.assertNotIn("tlsSettings", st)

    def test_xhttp_tls_with_extra_and_pin(self) -> None:
        cfg = xray_client.build_client_config(XHTTP, 10808, pinned_sha256="ab" * 32)
        st = self.outbound(cfg)["streamSettings"]
        self.assertEqual((st["network"], st["security"]), ("xhttp", "tls"))
        self.assertEqual(st["xhttpSettings"]["path"], "/api/v2/a1b2c3d4e5f6")
        self.assertEqual(st["xhttpSettings"]["host"], DOMAIN)
        self.assertEqual(st["xhttpSettings"]["extra"], {"xPaddingBytes": "100-1000"})
        self.assertEqual(st["tlsSettings"]["alpn"], ["h2", "http/1.1"])
        self.assertEqual(st["tlsSettings"]["pinnedPeerCertSha256"], "ab" * 32)
        self.assertNotIn("flow", self.outbound(cfg)["settings"]["vnext"][0]["users"][0])

    def test_no_pin_by_default(self) -> None:
        st = self.outbound(xray_client.build_client_config(XHTTP, 10808))["streamSettings"]
        self.assertNotIn("pinnedPeerCertSha256", st["tlsSettings"])

    def test_address_override_keeps_sni(self) -> None:
        cfg = xray_client.build_client_config(REALITY, 10808, address="127.0.0.1")
        out = self.outbound(cfg)
        self.assertEqual(out["settings"]["vnext"][0]["address"], "127.0.0.1")
        self.assertEqual(out["streamSettings"]["realitySettings"]["serverName"], DOMAIN)

    def test_socks_inbound_only_on_loopback(self) -> None:
        inb = xray_client.build_client_config(REALITY, 10808)["inbounds"]
        self.assertEqual([(i["listen"], i["port"], i["protocol"]) for i in inb], [("127.0.0.1", 10808, "socks")])

    def test_rejects_non_vless(self) -> None:
        for bad in ("vmess://abc", "vless://host-only", f"vless://{UUID}@{DOMAIN}?type=tcp", ""):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                xray_client.build_client_config(bad, 10808)


class CertSha256Test(unittest.TestCase):
    def test_matches_openssl_der_digest_of_leaf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            key, crt = Path(tmp, "k.pem"), Path(tmp, "c.pem")
            openssl = shutil.which("openssl") or "/usr/bin/openssl"
            for cn, out in (("leaf", crt), ("ca", Path(tmp, "ca.pem"))):
                cmd = [openssl, "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1", "-nodes"]
                cmd += ["-days", "1", "-subj", f"/CN={cn}", "-keyout", str(key), "-out", str(out)]
                subprocess.run(cmd, check=True, capture_output=True)  # noqa: S603
            leaf = crt.read_text()
            # fullchain.pem: листовой сертификат, затем промежуточный — закрепляется листовой.
            crt.write_text(leaf + Path(tmp, "ca.pem").read_text())
            want = hashlib.sha256(ssl.PEM_cert_to_DER_cert(leaf)).hexdigest()
            self.assertEqual(xray_client.cert_sha256(str(crt)), want)
            key.write_text("no cert here")
            with self.assertRaises(ValueError):
                xray_client.cert_sha256(str(key))


class ProbeTest(unittest.TestCase):
    def test_missing_xray_binary_is_reported_not_raised(self) -> None:
        res = xray_client.probe("/nonexistent/xray", REALITY, "https://www.gstatic.com/generate_204")
        self.assertFalse(res["ok"])
        self.assertIn("не удалось запустить", res["error"])

    def test_cli_exit_code_follows_result(self) -> None:
        argv = [
            "xray_client.py",
            "probe",
            "--xray",
            "/x",
            f"--link={REALITY}",
            "--url",
            "https://e.org",
            "--resolve",
            f"{DOMAIN}:127.0.0.1",
        ]
        for ok, code in ((True, 0), (False, 1)):
            with (
                self.subTest(ok=ok),
                mock.patch.object(sys, "argv", argv),
                mock.patch.object(xray_client, "probe", return_value={"ok": ok, "http_code": "204", "error": ""}) as p,
                contextlib.redirect_stdout(io.StringIO()),
            ):
                self.assertEqual(xray_client.main(), code)
                # --resolve для домена из ссылки подменяет адрес подключения.
                self.assertEqual(p.call_args.args[4], "127.0.0.1")


if __name__ == "__main__":
    unittest.main()
