"""Модульные тесты lib/update_antiscan.py: парсинг списков, allowlist, конфиг nftables и fallback."""

from __future__ import annotations

import ipaddress
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import update_antiscan  # noqa: E402


class ParseSshPortTest(unittest.TestCase):
    def test_reads_port_and_falls_back_to_22(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state.env"
            self.assertEqual(update_antiscan.read_ssh_port(str(state)), 22)

            state.write_text("DOMAIN=example.com\nSSH_PORT='22444'\n", encoding="utf-8")
            self.assertEqual(update_antiscan.read_ssh_port(str(state)), 22444)


class AllowlistTest(unittest.TestCase):
    def test_filters_non_global_ignores_comments_and_collapses(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            allow = Path(tmp) / "allow.txt"
            allow.write_text(
                "\n".join(
                    [
                        "# comment",
                        "192.168.1.0/24 # private ignored",
                        "invalid-cidr",
                        "93.184.216.0/25",
                        "93.184.216.128/25 # adjacent collapses to /24",
                    ]
                ),
                encoding="utf-8",
            )
            nets = update_antiscan.load_allowlist(str(allow))
            self.assertEqual(nets, [ipaddress.IPv4Network("93.184.216.0/24")])


class CollectScannersTest(unittest.TestCase):
    def test_parses_ripe_and_text_skips_html_and_broad_prefixes(self) -> None:
        ripe = json.dumps({"data": {"prefixes": [{"prefix": "45.155.205.0/24"}, {"prefix": "2001:db8::/32"}]}})
        responses = {
            "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS61280": ripe,
            "https://example.com/list1.txt": "93.184.216.10\n10.0.0.0/8\n8.0.0.0/8\n93.184.216.11/32\n",
            "https://example.com/html.txt": "<html><body>Rate limited</body></html>",
        }

        def fake_fetch(url: str) -> str:
            if url not in responses:
                raise OSError("network down")
            return responses[url]

        nets = update_antiscan.collect_scanners(
            fetch_fn=fake_fetch,
            text_urls=[
                "https://example.com/list1.txt",
                "https://example.com/html.txt",
                "https://example.com/missing.txt",
            ],
            static_scanners=["1.2.3.0/24"],
        )
        self.assertIn(ipaddress.IPv4Network("1.2.3.0/24"), nets)
        self.assertIn(ipaddress.IPv4Network("45.155.205.0/24"), nets)
        self.assertIn(ipaddress.IPv4Network("93.184.216.10/31"), nets)
        self.assertNotIn(ipaddress.IPv4Network("10.0.0.0/8"), nets)
        self.assertNotIn(ipaddress.IPv4Network("8.0.0.0/8"), nets)

    def test_default_sources_include_c24be_skipa_and_shadow_netlab(self) -> None:
        urls = "\n".join(update_antiscan.TEXT_URLS)
        self.assertIn("C24Be/AS_Network_List/main/blacklists/blacklist-v4.txt", urls)
        self.assertIn("CyberOK_Skipa_ips/main/lists/skipa_cidr.txt", urls)
        self.assertIn("shadow-netlab/traffic-guard-lists/main/public/antiscanner.list", urls)


class BuildNftConfigTest(unittest.TestCase):
    def test_with_and_without_allowlist(self) -> None:
        scanners = [ipaddress.IPv4Network("192.0.2.0/24")]
        cfg_no_allow = update_antiscan.build_nft_config(scanners, [], 2222)
        self.assertNotIn("allow_v4", cfg_no_allow)
        self.assertIn("tcp dport 2222 accept", cfg_no_allow)
        self.assertIn("192.0.2.0/24", cfg_no_allow)

        cfg_allow = update_antiscan.build_nft_config(scanners, [ipaddress.IPv4Network("198.51.100.5/32")], 2222)
        self.assertIn("set allow_v4", cfg_allow)
        self.assertIn("ip saddr @allow_v4 accept", cfg_allow)
        self.assertIn("198.51.100.5/32", cfg_allow)


class UpdateAntiscanFallbackTest(unittest.TestCase):
    def test_preserves_existing_file_when_below_min_nets(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            nft_file = Path(tmp) / "antiscan.nft"
            nft_file.write_text("# existing rules\n", encoding="utf-8")
            calls: list[list[str]] = []

            def fake_fetch(_url: str) -> str:
                raise OSError("offline")

            rc = update_antiscan.update_antiscan(
                nft_file=str(nft_file),
                allow_file=str(Path(tmp) / "allow.txt"),
                state_file=str(Path(tmp) / "state.env"),
                min_nets=30,
                fetch_fn=fake_fetch,
                run_fn=lambda cmd, **_kw: calls.append(cmd),
            )
            self.assertEqual(rc, 0)
            self.assertEqual(nft_file.read_text(encoding="utf-8"), "# existing rules\n")
            self.assertEqual(calls, [])

    def test_writes_static_fallback_on_initial_install_when_offline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            nft_file = Path(tmp) / "nested" / "antiscan.nft"
            state_file = Path(tmp) / "state.env"
            state_file.write_text("SSH_PORT=22022\n", encoding="utf-8")
            calls: list[list[str]] = []

            def fake_fetch(_url: str) -> str:
                raise OSError("offline")

            rc = update_antiscan.update_antiscan(
                nft_file=str(nft_file),
                allow_file=str(Path(tmp) / "allow.txt"),
                state_file=str(state_file),
                min_nets=30,
                fetch_fn=fake_fetch,
                run_fn=lambda cmd, **_kw: calls.append(cmd),
            )
            self.assertEqual(rc, 0)
            self.assertTrue(nft_file.is_file())
            content = nft_file.read_text(encoding="utf-8")
            self.assertIn("tcp dport 22022 accept", content)
            self.assertIn("199.45.154.0/23", content)
            self.assertEqual(len(calls), 2)
            self.assertEqual(calls[0][1:3], ["-c", "-f"])
            self.assertEqual(calls[1][1:2], ["-f"])


if __name__ == "__main__":
    unittest.main()
