#!/usr/bin/env python3
"""Разбор, отображение и выборочный выбор записей блокировок CrowdSec (`cscli decisions list -o json`).

Используется из `my3xui security` для интерактивного и пакетного удаления решений CrowdSec.
"""

from __future__ import annotations

import argparse
import json
import re
import sys


def parse_decisions(raw_json: str) -> list[dict[str, str]]:
    """Преобразует JSON от `cscli decisions list -o json` в плоский список решений."""
    text = raw_json.strip()
    if not text or text == "null":
        return []
    data = json.loads(text)
    if not data:
        return []
    if not isinstance(data, list):
        raise ValueError("Ожидался JSON-массив от cscli decisions list")

    out: list[dict[str, str]] = []
    seen_ids: set[str] = set()
    for item in data:
        if not isinstance(item, dict):
            continue
        if "decisions" in item:
            alert_scenario = str(item.get("scenario") or "")
            nested = item.get("decisions") or []
            if not isinstance(nested, list):
                continue
            for dec in nested:
                _append_decision(out, seen_ids, dec, alert_scenario)
        elif "id" in item and "value" in item:
            _append_decision(out, seen_ids, item, "")
    return out


def _append_decision(
    out: list[dict[str, str]],
    seen_ids: set[str],
    dec: object,
    fallback_scenario: str,
) -> None:
    if not isinstance(dec, dict) or dec.get("id") is None:
        return
    dec_id = str(dec["id"])
    if dec_id in seen_ids:
        return
    seen_ids.add(dec_id)
    out.append(
        {
            "id": dec_id,
            "value": str(dec.get("value") or ""),
            "type": str(dec.get("type") or ""),
            "scope": str(dec.get("scope") or ""),
            "scenario": str(dec.get("scenario") or fallback_scenario or ""),
            "duration": str(dec.get("duration") or ""),
            "origin": str(dec.get("origin") or ""),
        }
    )


def format_table(decisions: list[dict[str, str]]) -> str:
    """Форматирует нумерованный список блокировок для терминала (включая узкий экран Termius)."""
    if not decisions:
        return ""
    idx_w = len(str(len(decisions)))
    id_w = max(len(d["id"]) for d in decisions)
    val_w = min(max(len(d["value"]) for d in decisions), 22)
    type_w = max(len(d["type"] or "-") for d in decisions)

    lines: list[str] = []
    for i, d in enumerate(decisions, start=1):
        scenario = d["scenario"] or d["origin"] or "-"
        dur = f" ({d['duration']})" if d["duration"] else ""
        lines.append(
            f"  [{i:>{idx_w}}] ID:{d['id']:<{id_w}}  {d['value']:<{val_w}}  "
            f"{(d['type'] or '-'):<{type_w}}  {scenario}{dur}"
        )
    return "\n".join(lines)


def resolve_selection(decisions: list[dict[str, str]], query: str) -> tuple[list[dict[str, str]], bool]:
    """Разбирает выбор пользователя (номера, диапазоны, IP/значение, id:<N>, all).

    Возвращает `(выбранные_записи, is_all)`. При ошибке ввода бросает `ValueError`.
    """
    q = query.strip()
    if not q or q.lower() in {"0", "q", "quit", "exit"}:
        return [], False
    if q.lower() in {"all", "*"}:
        return list(decisions), True

    tokens = [t for t in re.split(r"[\s,]+", q) if t]
    selected: list[dict[str, str]] = []
    seen_ids: set[str] = set()

    def add_item(item: dict[str, str]) -> None:
        if item["id"] not in seen_ids:
            seen_ids.add(item["id"])
            selected.append(item)

    for token in tokens:
        if re.fullmatch(r"\d+", token):
            idx = int(token)
            if not (1 <= idx <= len(decisions)):
                raise ValueError(f"Номер вне диапазона (1-{len(decisions)}): {token}")
            add_item(decisions[idx - 1])
        elif m := re.fullmatch(r"(\d+)-(\d+)", token):
            start, end = int(m.group(1)), int(m.group(2))
            if not (1 <= start <= end <= len(decisions)):
                raise ValueError(f"Некорректный диапазон (1-{len(decisions)}): {token}")
            for idx in range(start, end + 1):
                add_item(decisions[idx - 1])
        elif token.lower().startswith("id:") and token[3:].isdigit():
            target_id = token[3:]
            matches = [d for d in decisions if d["id"] == target_id]
            if not matches:
                raise ValueError(f"Блокировка с ID {target_id} не найдена в списке")
            for item in matches:
                add_item(item)
        else:
            matches = [d for d in decisions if d["value"] == token]
            if not matches:
                raise ValueError(f"Запись не найдена: {token}")
            for item in matches:
                add_item(item)

    return selected, False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list", help="Вывести нумерованный список блокировок из stdin")
    sel = sub.add_parser("select", help="Выбрать записи по запросу пользователя")
    sel.add_argument("--query", required=True)
    args = parser.parse_args()

    raw_json = sys.stdin.read()
    try:
        decisions = parse_decisions(raw_json)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"Ошибка разбора JSON CrowdSec: {exc}", file=sys.stderr)
        return 1

    if args.cmd == "list":
        table = format_table(decisions)
        if table:
            print(table)
        return 0

    try:
        chosen, is_all = resolve_selection(decisions, args.query)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 1

    flag = "all" if is_all else "part"
    print(f"META\t{flag}\t{len(chosen)}")
    for item in chosen:
        print(f"ITEM\t{item['id']}\t{item['value']}\t{item['type']}\t{item['scenario']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
