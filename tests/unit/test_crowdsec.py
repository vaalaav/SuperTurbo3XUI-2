"""Модульные тесты lib/crowdsec.py: разбор, форматирование и выборочный выбор блокировок CrowdSec.

Запуск: python3 -m unittest discover -s tests/unit -v
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "lib"))
import crowdsec  # noqa: E402

SAMPLE_ALERTS = json.dumps(
    [
        {
            "id": 10,
            "scenario": "crowdsecurity/ssh-bf",
            "decisions": [
                {
                    "id": 42,
                    "origin": "crowdsec",
                    "type": "ban",
                    "scope": "Ip",
                    "value": "185.220.101.5",
                    "duration": "3h45m",
                    "scenario": "crowdsecurity/ssh-bf",
                }
            ],
        },
        {
            "id": 11,
            "scenario": "crowdsecurity/http-probing",
            "decisions": [
                {
                    "id": 43,
                    "origin": "crowdsec",
                    "type": "ban",
                    "scope": "Ip",
                    "value": "45.155.205.91",
                    "duration": "3h58m",
                },
                {
                    "id": 44,
                    "origin": "cscli",
                    "type": "ban",
                    "scope": "Range",
                    "value": "91.240.118.0/24",
                    "duration": "2h10m",
                    "scenario": "manual",
                },
            ],
        },
    ]
)


class ParseDecisionsTest(unittest.TestCase):
    def test_empty_and_null_inputs(self) -> None:
        self.assertEqual(crowdsec.parse_decisions(""), [])
        self.assertEqual(crowdsec.parse_decisions("null\n"), [])
        self.assertEqual(crowdsec.parse_decisions("[]"), [])

    def test_parses_alerts_and_inherits_scenario(self) -> None:
        items = crowdsec.parse_decisions(SAMPLE_ALERTS)
        self.assertEqual([d["id"] for d in items], ["42", "43", "44"])
        self.assertEqual(items[1]["scenario"], "crowdsecurity/http-probing")
        self.assertEqual(items[2]["value"], "91.240.118.0/24")

    def test_parses_flat_decisions_and_deduplicates(self) -> None:
        raw = json.dumps(
            [
                {"id": 7, "value": "1.2.3.4", "type": "ban", "scenario": "manual"},
                {"id": 7, "value": "1.2.3.4", "type": "ban", "scenario": "manual"},
            ]
        )
        items = crowdsec.parse_decisions(raw)
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["id"], "7")


class FormatAndSelectTest(unittest.TestCase):
    def setUp(self) -> None:
        self.items = crowdsec.parse_decisions(SAMPLE_ALERTS)

    def test_format_table_shows_numbered_entries(self) -> None:
        table = crowdsec.format_table(self.items)
        self.assertIn("[1] ID:42", table)
        self.assertIn("185.220.101.5", table)
        self.assertIn("[3] ID:44", table)
        self.assertIn("91.240.118.0/24", table)
        self.assertEqual(crowdsec.format_table([]), "")

    def test_select_single_comma_space_and_range(self) -> None:
        chosen, is_all = crowdsec.resolve_selection(self.items, "1, 3")
        self.assertFalse(is_all)
        self.assertEqual([d["id"] for d in chosen], ["42", "44"])

        chosen_range, is_all = crowdsec.resolve_selection(self.items, "1-2 2")
        self.assertFalse(is_all)
        self.assertEqual([d["id"] for d in chosen_range], ["42", "43"])

    def test_select_by_ip_or_decision_id_prefix(self) -> None:
        chosen, is_all = crowdsec.resolve_selection(self.items, "45.155.205.91 id:44")
        self.assertFalse(is_all)
        self.assertEqual([d["id"] for d in chosen], ["43", "44"])

    def test_select_all_and_cancel(self) -> None:
        chosen, is_all = crowdsec.resolve_selection(self.items, "all")
        self.assertTrue(is_all)
        self.assertEqual(len(chosen), 3)

        for cancel in ("", "0", "q"):
            chosen, is_all = crowdsec.resolve_selection(self.items, cancel)
            self.assertFalse(is_all)
            self.assertEqual(chosen, [])

    def test_rejects_out_of_range_and_unknown_values(self) -> None:
        for bad in ("4", "2-1", "0-2", "192.0.2.1", "id:999"):
            with self.assertRaises(ValueError):
                crowdsec.resolve_selection(self.items, bad)

    def test_cli_select_outputs_tsv(self) -> None:
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            # Имитируем вызов CLI main() с аргументом, начинающимся не с '-'
            old_argv, old_stdin = sys.argv, sys.stdin
            try:
                sys.argv = ["crowdsec.py", "select", "--query=1,3"]
                sys.stdin = io.StringIO(SAMPLE_ALERTS)
                rc = crowdsec.main()
            finally:
                sys.argv, sys.stdin = old_argv, old_stdin
        self.assertEqual(rc, 0)
        lines = buf.getvalue().strip().splitlines()
        self.assertEqual(lines[0], "META\tpart\t2")
        self.assertTrue(lines[1].startswith("ITEM\t42\t185.220.101.5\t"))
        self.assertTrue(lines[2].startswith("ITEM\t44\t91.240.118.0/24\t"))


if __name__ == "__main__":
    unittest.main()
