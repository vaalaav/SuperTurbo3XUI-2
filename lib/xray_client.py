#!/usr/bin/env python3
"""Проверка VPN-профиля по ссылке vless://: временный клиент Xray с SOCKS5 на loopback и HTTP-запрос через него.

Ссылка берётся такой, какой её отдаёт панель или подписка, поэтому проверяется ровно то, что получит клиент
(UUID, flow, SNI, путь и параметры XHTTP). Используют `my3xui audit` и сквозные тесты CI.

    xray_client.py probe --xray /usr/local/x-ui/bin/xray-linux-amd64 --link 'vless://…' \\
        --url https://www.gstatic.com/generate_204 [--pin-sha256 HEX] [--resolve HOST:IP]

Печатает JSON {"ok": bool, "http_code": str, "error": str} и завершается с кодом 0 только при ok.
--pin-sha256 закрепляет сертификат TLS сервера (нужно для самоподписанного сертификата в тестах).
--resolve подменяет адрес сервера из ссылки, не трогая SNI и Host (как curl --resolve).
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.parse


def parse_vless(link: str) -> tuple[urllib.parse.SplitResult, dict[str, str]]:
    u = urllib.parse.urlsplit(link.strip())
    if u.scheme != "vless" or not u.username or not u.hostname or not u.port:
        raise ValueError(f"Не ссылка vless://uuid@host:port: {link[:60]}")
    return u, dict(urllib.parse.parse_qsl(u.query))


def build_client_config(link: str, socks_port: int, pinned_sha256: str = "", address: str = "") -> dict:
    """Клиентский конфиг Xray из ссылки vless:// (TCP+Reality+Vision или XHTTP+TLS)."""
    u, q = parse_vless(link)
    user: dict = {"id": u.username, "encryption": q.get("encryption", "none")}
    if q.get("flow"):
        user["flow"] = q["flow"]
    network, security = q.get("type", "tcp"), q.get("security", "none")
    stream: dict = {"network": network, "security": security}
    if security == "reality":
        stream["realitySettings"] = {
            "serverName": q.get("sni", u.hostname),
            "fingerprint": q.get("fp", "chrome"),
            "publicKey": q["pbk"],
            "shortId": q.get("sid", ""),
            "spiderX": q.get("spx", "/"),
        }
        if q.get("pqv"):
            stream["realitySettings"]["mldsa65Verify"] = q["pqv"]
    elif security == "tls":
        tls: dict = {"serverName": q.get("sni", u.hostname), "fingerprint": q.get("fp", "chrome")}
        if q.get("alpn"):
            tls["alpn"] = q["alpn"].split(",")
        if pinned_sha256:
            tls["pinnedPeerCertSha256"] = pinned_sha256
        stream["tlsSettings"] = tls
    if network == "xhttp":
        stream["xhttpSettings"] = {
            "host": q.get("host", ""),
            "path": q.get("path", "/"),
            "mode": q.get("mode", "auto"),
            "extra": json.loads(q["extra"]) if q.get("extra") else {},
        }
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [{"listen": "127.0.0.1", "port": socks_port, "protocol": "socks", "settings": {"udp": False}}],
        "outbounds": [
            {
                "protocol": "vless",
                "settings": {"vnext": [{"address": address or u.hostname, "port": u.port, "users": [user]}]},
                "streamSettings": stream,
            }
        ],
    }


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def wait_port(port: int, timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.1)
    return False


def probe(xray: str, link: str, url: str, pinned_sha256: str = "", address: str = "", timeout: int = 20) -> dict:
    """Запускает клиент Xray по ссылке и делает запрос url через его SOCKS5."""
    port = free_port()
    cfg = build_client_config(link, port, pinned_sha256, address)
    with tempfile.TemporaryDirectory() as tmp:
        cfg_path = os.path.join(tmp, "client.json")
        with open(cfg_path, "w", encoding="utf-8") as f:
            json.dump(cfg, f)
        log_path = os.path.join(tmp, "xray.log")
        try:
            with open(log_path, "w", encoding="utf-8") as log:
                proc = subprocess.Popen([xray, "run", "-c", cfg_path], stdout=log, stderr=subprocess.STDOUT)  # noqa: S603
        except OSError as e:
            return {"ok": False, "http_code": "000", "error": f"не удалось запустить {xray}: {e}"}
        try:
            if not wait_port(port, 10):
                with open(log_path, encoding="utf-8", errors="replace") as log:
                    return {"ok": False, "http_code": "000", "error": "клиент Xray не запустился: " + log.read()[-300:]}
            # Без переменных прокси окружения: запрос должен идти только через проверяемый туннель.
            env = {k: v for k, v in os.environ.items() if "proxy" not in k.lower()}
            curl = ["curl", "-sS", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", str(timeout)]
            curl += ["--socks5-hostname", f"127.0.0.1:{port}", url]
            res = subprocess.run(curl, capture_output=True, text=True, env=env, check=False)  # noqa: S603
            code = res.stdout.strip() or "000"
            ok = res.returncode == 0 and code not in ("000", "")
            return {"ok": ok, "http_code": code, "error": "" if ok else res.stderr.strip()[-200:]}
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("probe")
    p.add_argument("--xray", required=True)
    p.add_argument("--link", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--pin-sha256", default="")
    p.add_argument("--resolve", default="", help="HOST:IP — подключаться к IP вместо адреса из ссылки")
    p.add_argument("--timeout", type=int, default=20)
    args = parser.parse_args()
    address = ""
    if args.resolve:
        host, _, ip = args.resolve.rpartition(":")
        if not host or not ip:
            parser.error("--resolve ожидает HOST:IP")
        address = ip if parse_vless(args.link)[0].hostname == host else ""
    result = probe(args.xray, args.link, args.url, args.pin_sha256, address, args.timeout)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
