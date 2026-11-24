#!/usr/bin/env python3
import json
import os
import pathlib
import sys
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xui_api  # noqa: E402 — импорт после добавления каталога lib в sys.path

e = os.environ
base = f"http://127.0.0.1:{e['PANEL_PORT']}/{e['PANEL_PATH']}"
# Постоянный токен проекта (ensure_xui_api_token в lib/common.sh). Вызов -getApiToken здесь
# перевыпускал бы токен при каждом запуске и аннулировал предыдущий.
tok = e.get("XUI_API_TOKEN", "").strip()
if not tok:
    sys.exit("XUI_API_TOKEN не задан: модуль должен вызвать ensure_xui_api_token перед этим скриптом.")
def req(path, data=None, form=False):
    h = {"Authorization": "Bearer " + tok}
    body = urllib.parse.urlencode(data).encode() if form else json.dumps(data or {}).encode()
    h["Content-Type"] = "application/x-www-form-urlencoded" if form else "application/json"
    with urllib.request.urlopen(urllib.request.Request(base + path, body, h), timeout=20) as r:
        res = json.loads(r.read().decode())
    if isinstance(res, dict) and res.get("success") is False:
        raise RuntimeError(f"API 3x-ui отклонил {path}: {res.get('msg') or res}")
    return res
s = req("/panel/api/setting/all")["obj"]
jp = "/" + (s.get("subJsonPath") or os.urandom(8).hex()).strip("/") + "/"
uri = xui_api.build_happ_routing_uri(e["DOMAIN"], e.get("GEO_PATH", ""), e.get("ENABLE_GEO_MIRROR", "").lower() in ("true", "y", "1"))
jr = json.dumps([
    {"type": "field", "outboundTag": "direct", "ip": ["geoip:private", "geoip:ru"]},
    {"type": "field", "outboundTag": "direct", "domain": ["geosite:category-ru", "geosite:ru-available-only-inside", "domain:ru", "domain:su", "domain:xn--p1ai"]}])
for k in ("subEnable", "subJsonEnable", "subHappAutoDetect", "happLinkEnable", "subEnableRouting",
          "subIncyAppAutoDetect", "subIncyEnableRouting"):
    s[k] = True
s.update(subJsonPath=jp, subJsonURI=f"https://{e['DOMAIN']}{jp}", subJsonRules=jr, subRoutingRules=uri, subIncyRoutingRules=uri)
req("/panel/api/setting/update", s)
sp = pathlib.Path("/etc/3xui-node/state.env")
if sp.exists():
    ls = [line for line in sp.read_text().splitlines() if not line.startswith("SUB_JSON_PATH=")]
    sp.write_text("\n".join(ls + [f"SUB_JSON_PATH={jp.strip('/')}"]) + "\n")
