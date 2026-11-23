#!/usr/bin/env python3
import json, os, pathlib, re, subprocess, sys, urllib.parse, urllib.request
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xui_api
e = os.environ
base = f"http://127.0.0.1:{e['PANEL_PORT']}/{e['PANEL_PATH']}"
out = subprocess.check_output(["/usr/local/x-ui/x-ui", "setting", "-getApiToken"], text=True, stderr=subprocess.STDOUT)
tok = re.search(r"apiToken:\s*(\S+)", out).group(1)
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
for k in ("subEnable","subJsonEnable","subHappAutoDetect","happLinkEnable","subEnableRouting","subIncyAppAutoDetect","subIncyEnableRouting"): s[k] = True
s.update(subJsonPath=jp, subJsonURI=f"https://{e['DOMAIN']}{jp}", subJsonRules=jr, subRoutingRules=uri, subIncyRoutingRules=uri)
req("/panel/api/setting/update", s)
sp = pathlib.Path("/etc/3xui-node/state.env")
if sp.exists():
    ls = [l for l in sp.read_text().splitlines() if not l.startswith("SUB_JSON_PATH=")]
    sp.write_text("\n".join(ls + [f"SUB_JSON_PATH={jp.strip('/')}"]) + "\n")
t = xui_api.build_base_xray_template(os.path.exists("/usr/local/x-ui/bin/geosite_RU.dat"))
o = req("/panel/api/xray/").get("obj")
for _ in (1, 2, 3): o = json.loads(o) if isinstance(o, str) and o.strip() else o.get("xraySetting", o) if isinstance(o, dict) else {}
t = xui_api.merge_custom_into_base(t, o)
req("/panel/api/xray/update", {"xraySetting": json.dumps(t, indent=2)}, form=True)
req("/panel/api/server/restartXrayService")
