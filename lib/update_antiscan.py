#!/usr/bin/env python3
"""Обновляет nftables-таблицу антисканера (inet antiscan) из списков сетей сканеров."""

from __future__ import annotations

import ipaddress
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
from typing import Callable

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

_IPV4_CIDR_RE = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}(?:/\d{1,2})?\b")


def read_ssh_port(state_file: str = STATE_FILE) -> int:
    """Читает SSH_PORT из state.env или возвращает 22."""
    if os.path.isfile(state_file):
        with open(state_file, encoding="utf-8", errors="ignore") as f:
            for line in f:
                if line.startswith("SSH_PORT="):
                    val = line.split("=", 1)[1].strip().strip("'\"")
                    if val.isdigit():
                        return int(val)
    return 22


def fetch(url: str) -> str:
    """Загружает текстовый ресурс по HTTPS с таймаутом."""
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urllib.request.urlopen(req, timeout=15) as resp:
        return resp.read().decode("utf-8", errors="ignore")


def fetch_ripe_as61280(fetch_fn: Callable[[str], str] = fetch) -> list[str]:
    """Возвращает анонсированные IPv4-префиксы AS61280 из RIPEstat."""
    out: list[str] = []
    try:
        raw = fetch_fn("https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS61280")
        data = json.loads(raw)
        for item in data.get("data", {}).get("prefixes", []):
            prefix = item.get("prefix", "")
            if "." in prefix:
                out.append(prefix)
    except Exception as exc:
        print(f"WARN: RIPEstat AS61280 unavailable: {exc}")
    return out


def load_allowlist(allow_file: str = ALLOW_FILE) -> list[ipaddress.IPv4Network]:
    """Загружает и схлопывает белый список IPv4/CIDR из allow-файла."""
    allowed: set[ipaddress.IPv4Network] = set()
    if os.path.isfile(allow_file):
        with open(allow_file, encoding="utf-8", errors="ignore") as f:
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


def collect_scanners(
    fetch_fn: Callable[[str], str] = fetch,
    text_urls: list[str] | tuple[str, ...] = TEXT_URLS,
    static_scanners: list[str] | tuple[str, ...] = STATIC_SCANNERS,
) -> list[ipaddress.IPv4Network]:
    """Собирает, фильтрует (global, >= /16) и агрегирует IPv4-сети сканеров."""
    candidates = list(static_scanners)
    candidates.extend(fetch_ripe_as61280(fetch_fn=fetch_fn))

    for url in text_urls:
        try:
            text = fetch_fn(url)
            if "<html" in text.lower():
                continue
            candidates.extend(_IPV4_CIDR_RE.findall(text))
        except Exception as exc:
            print(f"WARN: failed {url}: {exc}")

    valid: set[ipaddress.IPv4Network] = set()
    for item in candidates:
        try:
            net = ipaddress.IPv4Network(item, strict=False)
            if net.is_global and net.prefixlen >= 16:
                valid.add(net)
        except ValueError:
            continue
    return list(ipaddress.collapse_addresses(valid))


def build_nft_config(
    scanners: list[ipaddress.IPv4Network],
    allow_nets: list[ipaddress.IPv4Network],
    ssh_port: int,
) -> str:
    """Формирует конфигурацию nftables для таблицы inet antiscan."""
    scanners_block = ",\n        ".join(str(n) for n in scanners)
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

    return f"""table inet antiscan
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


def update_antiscan(
    nft_file: str = NFT_FILE,
    allow_file: str = ALLOW_FILE,
    state_file: str = STATE_FILE,
    min_nets: int = MIN_NETS,
    fetch_fn: Callable[[str], str] = fetch,
    run_fn: Callable[..., object] = subprocess.run,
) -> int:
    """Обновляет правила nftables. Возвращает код завершения."""
    collapsed = collect_scanners(fetch_fn=fetch_fn)
    if len(collapsed) < min_nets:
        if os.path.isfile(nft_file):
            print(f"WARN: получено слишком мало сетей ({len(collapsed)}), сохраняю текущие правила.")
            return 0
        if not collapsed:
            print("WARN: список сетей сканеров пуст, правила не созданы.")
            return 1
        print(f"WARN: внешние списки недоступны ({len(collapsed)} сетей < {min_nets}), применяю статический список.")

    allow_nets = load_allowlist(allow_file)
    ssh_port = read_ssh_port(state_file)
    nft_conf = build_nft_config(collapsed, allow_nets, ssh_port)

    os.makedirs(os.path.dirname(nft_file) or ".", exist_ok=True)
    tmp_file = f"{nft_file}.tmp"
    with open(tmp_file, "w", encoding="utf-8") as f:
        f.write(nft_conf)

    nft_bin = shutil.which("nft") or "/usr/sbin/nft"
    run_fn([nft_bin, "-c", "-f", tmp_file], check=True)  # noqa: S603
    os.replace(tmp_file, nft_file)
    run_fn([nft_bin, "-f", nft_file], check=True)  # noqa: S603
    print(f"OK: загружено {len(collapsed)} сжатых IPv4-подсетей сканеров (SSH:{ssh_port} защищён).")
    return 0


def main() -> int:
    return update_antiscan()


if __name__ == "__main__":
    sys.exit(main())
