#!/usr/bin/env python3
"""
Генератор и деплойер многостраничных веб-порталов для маскировки домена (Self-Steal / XHTTP).
Создаёт уникализированный статический сайт с подстраницами, ассетами (CSS, JS, SVG, favicon.ico),
robots.txt, sitemap.xml, страницей 404 и согласованным фрагментом API-роутинга для Nginx.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import secrets
import shutil
import struct
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_TEMPLATES_DIR = Path(__file__).resolve().parent.parent / "templates" / "sites"
DEFAULT_OUTPUT_DIR = Path("/var/www/masksite")
DEFAULT_API_CONF = Path("/etc/nginx/conf.d/masksite-api/site.conf")

REGIONS = (
    "eu-central-1",
    "eu-north-1",
    "eu-west-1",
    "eu-west-3",
)

REGION_CITIES = {
    "eu-central-1": "Frankfurt, DE",
    "eu-north-1": "Stockholm, SE",
    "eu-west-1": "Dublin, IE",
    "eu-west-3": "Paris, FR",
}

BRAND_PREFIXES = (
    "Arbor",
    "Boreal",
    "Caldera",
    "Cinder",
    "Cobalt",
    "Helix",
    "Kestrel",
    "Lumen",
    "Meridian",
    "Nord",
    "Quarry",
    "Sable",
    "Solstice",
    "Strata",
    "Trellis",
    "Vektor",
    "Vera",
)

DEFAULT_BRAND_NOUNS = ("Cloud", "Systems", "Platform", "Grid", "Labs", "Works")

UPTIME_VALUES = ("99.94%", "99.96%", "99.97%", "99.98%", "99.99%")


def _seed_int(seed: str, salt: str) -> int:
    digest = hashlib.sha256(f"{seed}:{salt}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big")


def _pick(seed: str, salt: str, items: list | tuple):
    return items[_seed_int(seed, salt) % len(items)]


def discover_templates(templates_dir: Path) -> dict[str, dict]:
    """Возвращает словарь доступных шаблонов {id: manifest} из templates/sites/*/manifest.json."""
    result: dict[str, dict] = {}
    if not templates_dir.is_dir():
        return result
    for entry in sorted(templates_dir.iterdir()):
        manifest_path = entry / "manifest.json"
        if entry.is_dir() and not entry.name.startswith("_") and manifest_path.is_file():
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["id"] = manifest.get("id") or entry.name
            manifest["_dir"] = str(entry)
            result[manifest["id"]] = manifest
    return result


def generate_brand_name(seed: str, nouns: list[str] | tuple[str, ...] | None = None) -> str:
    """Генерирует естественное B2B-название бренда без склейки субдомена."""
    pool = nouns if nouns else DEFAULT_BRAND_NOUNS
    prefix = _pick(seed, "brand_prefix", BRAND_PREFIXES)
    noun = _pick(seed, "brand_noun", pool)
    if _seed_int(seed, "brand_space") % 3 == 0:
        return f"{prefix} {noun}"
    return f"{prefix}{noun}"


def generate_favicon_ico(accent_hex: str, bg_hex: str) -> bytes:
    """Генерирует минимальный валидный 16x16 32-bit RGBA ICO без сторонних библиотек."""

    def parse_hex(col: str) -> tuple[int, int, int]:
        h = col.lstrip("#")
        if len(h) == 3:
            h = "".join(c * 2 for c in h)
        if len(h) != 6:
            return (56, 189, 248)
        return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))

    ar, ag, ab = parse_hex(accent_hex)
    br, bg, bb = parse_hex(bg_hex)
    size = 16
    pixels = bytearray()
    # BMP в ICO хранится снизу вверх (bottom-up), порядок каналов BGRA.
    for y in range(size - 1, -1, -1):
        for x in range(size):
            border = x in (0, size - 1) or y in (0, size - 1)
            glyph = (4 <= x <= 11 and y in (4, 5)) or (4 <= x <= 6 and 4 <= y <= 11) or (8 <= x <= 11 and 7 <= y <= 11)
            if border:
                r, g, b, a = ar, ag, ab, 255
            elif glyph:
                r, g, b, a = ar, ag, ab, 255
            else:
                r, g, b, a = br, bg, bb, 255
            pixels.extend((b, g, r, a))

    and_mask = b"\x00" * (size * 4)
    bmp_header = struct.pack(
        "<IIIHHIIIIII",
        40,  # biSize
        size,  # biWidth
        size * 2,  # biHeight (color + mask)
        1,  # biPlanes
        32,  # biBitCount
        0,  # biCompression (BI_RGB)
        len(pixels) + len(and_mask),
        0,
        0,
        0,
        0,
    )
    dib = bmp_header + bytes(pixels) + and_mask
    ico_header = struct.pack("<HHH", 0, 1, 1)
    ico_entry = struct.pack(
        "<BBBBHHII",
        size,
        size,
        0,
        0,
        1,
        32,
        len(dib),
        6 + 16,
    )
    return ico_header + ico_entry + dib


def build_replacements(
    manifest: dict,
    domain: str,
    seed: str,
    brand_name: str = "",
    node_region: str = "",
    app_ver: str = "",
    now: datetime | None = None,
) -> tuple[dict[str, str], dict[str, str]]:
    """Формирует карту плейсхолдеров и итоговые метаданные портала."""
    now_dt = now or datetime.now(timezone.utc)
    nouns = manifest.get("brand_nouns") or list(DEFAULT_BRAND_NOUNS)
    resolved_brand = brand_name.strip() or generate_brand_name(seed, nouns)
    resolved_region = node_region.strip() or _pick(seed, "region", REGIONS)
    if app_ver.strip():
        resolved_ver = app_ver.strip()
    else:
        minor = 1 + (_seed_int(seed, "ver_minor") % 6)
        patch = _seed_int(seed, "ver_patch") % 12
        resolved_ver = f"2.{minor}.{patch}"

    themes = manifest.get("themes") or [
        {
            "name": "default",
            "bg": "#0b1120",
            "surface": "#111827",
            "surface_alt": "#1e293b",
            "border": "#1f2937",
            "fg": "#e5e7eb",
            "muted": "#94a3b8",
            "accent": "#38bdf8",
            "accent_fg": "#082f49",
            "ok": "#34d399",
        }
    ]
    theme = _pick(seed, "theme", themes)

    taglines = manifest.get("taglines") or ["Managed infrastructure and edge services"]
    tagline = _pick(seed, "tagline", taglines)
    email_local = _pick(seed, "email_local", manifest.get("email_locals") or ["support", "ops", "hello", "noc"])
    contact_email = f"{email_local}@{domain}"
    uptime = _pick(seed, "uptime", UPTIME_VALUES)
    latency_ms = str(11 + (_seed_int(seed, "latency") % 26))
    nodes_count = str(12 + (_seed_int(seed, "nodes") % 36))
    throughput = str(40 + (_seed_int(seed, "gbps") % 120))
    start_year = 2021 + (_seed_int(seed, "start_year") % 3)
    cur_year = now_dt.year
    year_range = f"{start_year}–{cur_year}" if start_year < cur_year else str(cur_year)

    dt_1 = now_dt - timedelta(days=2 + (_seed_int(seed, "d1") % 4))
    dt_2 = now_dt - timedelta(days=9 + (_seed_int(seed, "d2") % 8))
    dt_3 = now_dt - timedelta(days=21 + (_seed_int(seed, "d3") % 14))
    date_1 = dt_1.strftime("%Y-%m-%d")
    date_2 = dt_2.strftime("%Y-%m-%d")
    date_3 = dt_3.strftime("%Y-%m-%d")
    region_city = REGION_CITIES.get(resolved_region, "Frankfurt, DE")

    brand_slug = "".join(ch.lower() if ch.isalnum() else "-" for ch in resolved_brand).strip("-")
    while "--" in brand_slug:
        brand_slug = brand_slug.replace("--", "-")

    replacements = {
        "__BRAND__": html.escape(resolved_brand),
        "__BRAND_RAW__": resolved_brand,
        "__BRAND_SLUG__": brand_slug or "portal",
        "__BRAND_INITIAL__": resolved_brand[0].upper(),
        "__DOMAIN__": domain,
        "__REGION__": resolved_region,
        "__REGION_CITY__": region_city,
        "__VERSION__": resolved_ver,
        "__TAGLINE__": html.escape(tagline),
        "__CONTACT_EMAIL__": contact_email,
        "__UPTIME__": uptime,
        "__LATENCY_MS__": latency_ms,
        "__NODES_COUNT__": nodes_count,
        "__THROUGHPUT__": throughput,
        "__YEAR__": str(cur_year),
        "__YEAR_RANGE__": year_range,
        "__ISO_DATE__": now_dt.strftime("%Y-%m-%d"),
        "__DATE_1__": date_1,
        "__DATE_2__": date_2,
        "__DATE_3__": date_3,
        "__RSS_DATE_1__": dt_1.strftime("%a, %d %b %Y 09:30:00 GMT"),
        "__RSS_DATE_2__": dt_2.strftime("%a, %d %b %Y 14:15:00 GMT"),
        "__RSS_DATE_3__": dt_3.strftime("%a, %d %b %Y 11:00:00 GMT"),
        "__THEME_BG__": theme["bg"],
        "__THEME_SURFACE__": theme["surface"],
        "__THEME_SURFACE_ALT__": theme["surface_alt"],
        "__THEME_BORDER__": theme["border"],
        "__THEME_FG__": theme["fg"],
        "__THEME_MUTED__": theme["muted"],
        "__THEME_ACCENT__": theme["accent"],
        "__THEME_ACCENT_FG__": theme["accent_fg"],
        "__THEME_OK__": theme["ok"],
    }

    meta = {
        "template": manifest["id"],
        "brand_name": resolved_brand,
        "brand_slug": brand_slug or "portal",
        "mask_seed": seed,
        "node_region": resolved_region,
        "app_ver": resolved_ver,
        "contact_email": contact_email,
        "uptime": uptime,
        "theme": theme.get("name", "default"),
        "accent": theme["accent"],
        "bg": theme["bg"],
    }
    return replacements, meta


def _apply_replacements(text: str, replacements: dict[str, str]) -> str:
    # Заменяем сначала длинные ключи, чтобы __BRAND_SLUG__ не перекрывался __BRAND__.
    for key in sorted(replacements, key=len, reverse=True):
        text = text.replace(key, replacements[key])
    return text


def render_robots_txt(domain: str, manifest: dict) -> str:
    disallow_paths = manifest.get("robots_disallow") or ["/api/", "/console/"]
    lines = ["User-agent: *", "Allow: /"]
    for p in disallow_paths:
        lines.append(f"Disallow: {p}")
    lines.append("")
    lines.append(f"Sitemap: https://{domain}/sitemap.xml")
    return "\n".join(lines) + "\n"


def render_sitemap_xml(domain: str, manifest: dict, iso_date: str) -> str:
    pages = manifest.get("pages") or ["/"]
    entries = []
    for p in pages:
        loc = f"https://{domain}{p}"
        priority = "1.0" if p == "/" else "0.8"
        entries.append(
            f"  <url>\n"
            f"    <loc>{html.escape(loc)}</loc>\n"
            f"    <lastmod>{iso_date}</lastmod>\n"
            f"    <priority>{priority}</priority>\n"
            f"  </url>"
        )
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + "\n".join(entries) + "\n</urlset>\n"
    )


def render_nginx_api_conf(manifest: dict, replacements: dict[str, str]) -> str:
    """Формирует конфигурацию API-заглушек Nginx, согласованную с конкретным шаблоном."""
    endpoints = manifest.get("api_endpoints") or []
    blocks = ["# Managed by lib/mask_site.py — do not edit manually"]
    for ep in endpoints:
        path = ep["path"]
        status = int(ep.get("status", 200))
        content_type = ep.get("content_type", "application/json")
        body = _apply_replacements(json.dumps(ep["body"], ensure_ascii=False, separators=(",", ":")), replacements)
        rate_limit = ep.get("rate_limit", "")
        escaped_body = body.replace("'", "\\'")
        limit_line = f"    limit_req zone={rate_limit};\n" if rate_limit else ""
        blocks.append(
            f"location = {path} {{\n"
            f"{limit_line}"
            f"    default_type {content_type};\n"
            f"    return {status} '{escaped_body}';\n"
            f"}}"
        )
    return "\n\n".join(blocks) + "\n"


def _clear_dir_contents(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    for item in path.iterdir():
        if item.is_dir() and not item.is_symlink():
            shutil.rmtree(item)
        else:
            item.unlink()


def deploy_site(
    templates_dir: Path,
    template_id: str,
    domain: str,
    output_dir: Path,
    nginx_api_conf: Path | None = None,
    brand_name: str = "",
    mask_seed: str = "",
    node_region: str = "",
    app_ver: str = "",
    now: datetime | None = None,
) -> dict:
    """Разворачивает выбранный шаблон портала в output_dir и генерирует конфиг API Nginx."""
    templates = discover_templates(templates_dir)
    if not templates:
        raise RuntimeError(f"В каталоге {templates_dir} не найдено ни одного шаблона портала.")

    seed = mask_seed.strip() or secrets.token_hex(4)
    if template_id == "random":
        template_id = _pick(seed, "template", sorted(templates))
    if template_id not in templates:
        fallback = "cloud-storage" if "cloud-storage" in templates else sorted(templates)[0]
        template_id = fallback

    manifest = templates[template_id]
    src_dir = Path(manifest["_dir"])
    replacements, meta = build_replacements(
        manifest=manifest,
        domain=domain,
        seed=seed,
        brand_name=brand_name,
        node_region=node_region,
        app_ver=app_ver,
        now=now,
    )

    _clear_dir_contents(output_dir)

    text_exts = {".html", ".css", ".js", ".svg", ".json", ".xml", ".txt", ".webmanifest"}
    files_written = 0
    for src_file in sorted(src_dir.rglob("*")):
        if not src_file.is_file() or src_file.name == "manifest.json":
            continue
        rel = src_file.relative_to(src_dir)
        dst_file = output_dir / rel
        dst_file.parent.mkdir(parents=True, exist_ok=True)
        if src_file.suffix.lower() in text_exts:
            raw = src_file.read_text(encoding="utf-8")
            dst_file.write_text(_apply_replacements(raw, replacements), encoding="utf-8")
        else:
            shutil.copy2(src_file, dst_file)
        files_written += 1

    # Генерируем стандартные артефакты веб-портала, если они не заданы вручную в шаблоне.
    if not (output_dir / "favicon.ico").exists():
        (output_dir / "favicon.ico").write_bytes(generate_favicon_ico(meta["accent"], meta["bg"]))
        files_written += 1

    if not (output_dir / "robots.txt").exists():
        (output_dir / "robots.txt").write_text(render_robots_txt(domain, manifest), encoding="utf-8")
        files_written += 1

    if not (output_dir / "sitemap.xml").exists():
        (output_dir / "sitemap.xml").write_text(
            render_sitemap_xml(domain, manifest, replacements["__ISO_DATE__"]),
            encoding="utf-8",
        )
        files_written += 1

    if nginx_api_conf is not None:
        nginx_api_conf.parent.mkdir(parents=True, exist_ok=True)
        nginx_api_conf.write_text(render_nginx_api_conf(manifest, replacements), encoding="utf-8")

    meta["files_count"] = files_written
    meta["pages_count"] = len(manifest.get("pages") or ["/"])
    return meta


def cleanup_api_conf(nginx_api_conf: Path) -> None:
    if nginx_api_conf.exists():
        nginx_api_conf.unlink()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Менеджер автономных порталов маскировки")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="Список доступных шаблонов")
    p_list.add_argument("--templates-dir", type=Path, default=DEFAULT_TEMPLATES_DIR)
    p_list.add_argument("--json", action="store_true", dest="as_json")

    p_deploy = sub.add_parser("deploy", help="Развернуть шаблон портала")
    p_deploy.add_argument("--templates-dir", type=Path, default=DEFAULT_TEMPLATES_DIR)
    p_deploy.add_argument("--template", default="cloud-storage")
    p_deploy.add_argument("--domain", required=True)
    p_deploy.add_argument("--output-dir", type=Path, default=DEFAULT_OUTPUT_DIR)
    p_deploy.add_argument("--nginx-api-conf", type=Path, default=DEFAULT_API_CONF)
    p_deploy.add_argument("--no-nginx-api-conf", action="store_true")
    p_deploy.add_argument("--brand-name", default="")
    p_deploy.add_argument("--mask-seed", default="")
    p_deploy.add_argument("--node-region", default="")
    p_deploy.add_argument("--app-ver", default="")

    p_clean = sub.add_parser("cleanup-api-conf", help="Удалить конфиг API-заглушек Nginx")
    p_clean.add_argument("--nginx-api-conf", type=Path, default=DEFAULT_API_CONF)

    args = parser.parse_args(argv)
    if args.cmd == "list":
        templates = discover_templates(args.templates_dir)
        if args.as_json:
            payload = [
                {
                    "id": tid,
                    "title": m.get("title", tid),
                    "description": m.get("description", ""),
                    "pages": len(m.get("pages") or []),
                }
                for tid, m in templates.items()
            ]
            print(json.dumps(payload, ensure_ascii=False))
        else:
            for tid, m in templates.items():
                print(f"{tid}\t{m.get('title', tid)}\t{m.get('description', '')}")
        return 0

    if args.cmd == "deploy":
        api_conf = None if args.no_nginx_api_conf else args.nginx_api_conf
        meta = deploy_site(
            templates_dir=args.templates_dir,
            template_id=args.template,
            domain=args.domain,
            output_dir=args.output_dir,
            nginx_api_conf=api_conf,
            brand_name=args.brand_name,
            mask_seed=args.mask_seed,
            node_region=args.node_region,
            app_ver=args.app_ver,
        )
        print(json.dumps(meta, ensure_ascii=False))
        return 0

    if args.cmd == "cleanup-api-conf":
        cleanup_api_conf(args.nginx_api_conf)
        return 0

    return 1


if __name__ == "__main__":
    if os.environ.get("DEBUG"):
        raise SystemExit(main())
    try:
        raise SystemExit(main())
    except Exception as exc:  # noqa: BLE001
        print(f"mask_site error: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
