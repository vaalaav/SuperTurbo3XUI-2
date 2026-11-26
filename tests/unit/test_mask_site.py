import json
import re
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "lib"))

import mask_site  # noqa: E402

TEMPLATES_DIR = REPO / "templates" / "sites"
UNRESOLVED_RE = re.compile(r"__[A-Z0-9_]+__")
ATTR_REF_RE = re.compile(r'(?:href|src)=["\'](/[^"\'#?]+)["\']')


class MaskSiteTests(unittest.TestCase):
    def test_discover_templates_finds_all_portals(self):
        templates = mask_site.discover_templates(TEMPLATES_DIR)
        self.assertEqual(
            set(templates.keys()),
            {"cloud-storage", "dev-docs", "saas-analytics", "status-hub", "tech-journal"},
        )

    def test_deploy_all_templates_complete_and_valid(self):
        templates = mask_site.discover_templates(TEMPLATES_DIR)
        for tid, manifest in templates.items():
            with tempfile.TemporaryDirectory() as tmp:
                out_dir = Path(tmp) / "masksite"
                api_conf = Path(tmp) / "masksite-api" / "site.conf"
                meta = mask_site.deploy_site(
                    templates_dir=TEMPLATES_DIR,
                    template_id=tid,
                    domain="portal.example.com",
                    output_dir=out_dir,
                    nginx_api_conf=api_conf,
                    mask_seed="abcd1234",
                )
                self.assertEqual(meta["template"], tid)
                self.assertTrue((out_dir / "index.html").is_file())
                self.assertTrue((out_dir / "404.html").is_file())
                self.assertTrue((out_dir / "robots.txt").is_file())
                self.assertTrue((out_dir / "sitemap.xml").is_file())
                self.assertTrue((out_dir / "site.webmanifest").is_file())
                self.assertTrue((out_dir / "assets" / "app.css").is_file())
                self.assertTrue((out_dir / "assets" / "app.js").is_file())
                self.assertTrue((out_dir / "assets" / "logo.svg").is_file())

                ico = (out_dir / "favicon.ico").read_bytes()
                self.assertEqual(ico[:4], b"\x00\x00\x01\x00")
                self.assertGreater(len(ico), 100)

                robots = (out_dir / "robots.txt").read_text(encoding="utf-8")
                self.assertIn("Allow: /", robots)
                self.assertIn("Sitemap: https://portal.example.com/sitemap.xml", robots)
                self.assertNotIn("Disallow: /\n", robots)

                root = ET.fromstring((out_dir / "sitemap.xml").read_text(encoding="utf-8"))  # noqa: S314
                locs = [el.text for el in root.findall(".//{http://www.sitemaps.org/schemas/sitemap/0.9}loc")]
                for page in manifest["pages"]:
                    self.assertIn(f"https://portal.example.com{page}", locs)

                api_paths = {ep["path"] for ep in manifest["api_endpoints"]}
                conf_text = api_conf.read_text(encoding="utf-8")
                for path in api_paths:
                    self.assertIn(f"location = {path}", conf_text)

                text_exts = {".html", ".css", ".js", ".svg", ".json", ".xml", ".txt", ".webmanifest"}
                for file_path in out_dir.rglob("*"):
                    if not file_path.is_file():
                        continue
                    if file_path.suffix.lower() in text_exts:
                        text = file_path.read_text(encoding="utf-8")
                        self.assertIsNone(
                            UNRESOLVED_RE.search(text),
                            msg=f"Незаменённый плейсхолдер в {tid}/{file_path.relative_to(out_dir)}",
                        )
                        self.assertNotIn("build-id", text.lower())
                        if file_path.suffix.lower() in {".json", ".webmanifest"}:
                            json.loads(text)
                        if file_path.suffix.lower() == ".xml":
                            ET.fromstring(text)  # noqa: S314
                        if file_path.suffix.lower() == ".html":
                            for ld in re.findall(
                                r'<script type="application/ld\+json">(.*?)</script>',
                                text,
                                flags=re.DOTALL,
                            ):
                                json.loads(ld)
                            for ref in ATTR_REF_RE.findall(text):
                                if ref in api_paths or ref == "/sitemap.xml":
                                    continue
                                target = out_dir / ref.lstrip("/")
                                resolved = target.is_file() or (target.is_dir() and (target / "index.html").is_file())
                                self.assertTrue(
                                    resolved,
                                    msg=f"Битая внутренняя ссылка {ref} в {tid}/{file_path.relative_to(out_dir)}",
                                )

    def test_seed_varies_branding_and_css(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_a = Path(tmp) / "a"
            out_b = Path(tmp) / "b"
            meta_a = mask_site.deploy_site(
                templates_dir=TEMPLATES_DIR,
                template_id="cloud-storage",
                domain="node1.example.com",
                output_dir=out_a,
                mask_seed="11111111",
            )
            meta_b = mask_site.deploy_site(
                templates_dir=TEMPLATES_DIR,
                template_id="cloud-storage",
                domain="node1.example.com",
                output_dir=out_b,
                mask_seed="99999999",
            )
            css_a = (out_a / "assets" / "app.css").read_text(encoding="utf-8")
            css_b = (out_b / "assets" / "app.css").read_text(encoding="utf-8")
            self.assertNotEqual((meta_a["brand_name"], css_a), (meta_b["brand_name"], css_b))

    def test_random_and_fallback_selection_and_cleanup(self):
        with tempfile.TemporaryDirectory() as tmp:
            out_dir = Path(tmp) / "masksite"
            api_conf = Path(tmp) / "site.conf"
            meta_rand = mask_site.deploy_site(
                templates_dir=TEMPLATES_DIR,
                template_id="random",
                domain="rand.example.com",
                output_dir=out_dir,
                nginx_api_conf=api_conf,
                mask_seed="feedface",
            )
            self.assertIn(
                meta_rand["template"],
                {"cloud-storage", "dev-docs", "saas-analytics", "status-hub", "tech-journal"},
            )
            self.assertTrue(api_conf.is_file())

            mask_site.cleanup_api_conf(api_conf)
            self.assertFalse(api_conf.exists())

            meta_fb = mask_site.deploy_site(
                templates_dir=TEMPLATES_DIR,
                template_id="nonexistent-template",
                domain="fb.example.com",
                output_dir=out_dir,
            )
            self.assertEqual(meta_fb["template"], "cloud-storage")


if __name__ == "__main__":
    unittest.main()
