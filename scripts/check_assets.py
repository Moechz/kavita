#!/usr/bin/env python3
"""check_assets.py - static asset self-check before release (invoked by `make check`)

Validated against the TOS 7 App Center specification:
    1. assets/config.ini.in is valid JSON (after rendering @@VERSION@@ and friends)
    2. assets/kavita.lang carries the 23-language superset (the device-tested 14 plus the
          officially documented 14), UTF-8 without BOM, LF endings; no 'beta' anywhere (review item V11)
    3. assets/appsettings-init.json is valid JSON with the correct safety-net values
          (IpAddresses=127.0.0.1 / Port=8500 / BaseUrl=/kavita/)
    4. every text asset under assets/ is free of CRLF / BOM
    5. the privacy policy exists and parses (review item C3, pitfall 45)
    6. icon SVG integrity: parseable XML + viewBox + fill (pitfall 47, a truncation case)
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
fail = 0

REQUIRED_LANGS = ["zh-cn", "zh-hk", "en-us", "fr-fr", "de-de", "it-it", "es-es",
                  "hu-hu", "ja-jp", "ko-kr", "pl-pl", "ru-ru", "tr-tr", "pt-pt",
                  "ar-sa", "cs-cz", "he-il", "id-id", "nb-no", "nl-nl", "sv-se",
                  "th-th", "vi-vn"]

# Keep in sync with APP_PORT in config.env (static safety-net assertion; update both when changing the port)
EXPECT_PORT = 8500

# ---------- 1. config.ini.in ----------
raw = (ROOT / "assets/config.ini.in").read_text(encoding="utf-8")
rendered = (raw.replace("@@VERSION@@", "0.0.0")
              .replace("@@PUBLISHER@@", "x")
              .replace("@@PLATFORM@@", "x86_64"))
try:
    json.loads(rendered)
    print("config.ini.in: valid JSON OK")
except Exception as e:  # noqa: BLE001
    print(f"config.ini.in: invalid JSON FAIL ({e})")
    fail = 1

# ---------- 2. lang ----------
lang_path = ROOT / "assets/kavita.lang"
data = lang_path.read_bytes()
if data.startswith(b"\xef\xbb\xbf"):
    print("lang: contains BOM FAIL")
    fail = 1
text = data.decode("utf-8")
found = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", text, re.M)
missing = [t for t in REQUIRED_LANGS if t not in found]
if missing:
    print(f"lang: missing language sections FAIL {missing}")
    fail = 1
else:
    print(f"lang: 23-language superset complete OK ({len(found)} sections)")

# Official app.lang hard limits (characters): name 64 / auth 64 / descript 512 / important 512
LANG_LIM = {"name": 64, "auth": 64, "descript": 512, "important": 512}
len_errs = []
_secs = re.split(r"^\[([a-z]{2}-[a-z]{2})\]$", text, flags=re.M)
for _i in range(1, len(_secs), 2):
    _code, _body = _secs[_i], _secs[_i + 1]
    for _f, _lim in LANG_LIM.items():
        _m = re.search(rf'^{_f}\s*=\s*"(.*)"$', _body, re.M)
        _v = _m.group(1) if _m else ""
        if not _v:
            len_errs.append(f"{_code}:{_f} empty")
        elif len(_v) > _lim:
            len_errs.append(f"{_code}:{_f}={len(_v)}>{_lim}")
if len_errs:
    print(f"lang: field length/empty violations FAIL {len_errs[:6]}{' ...' if len(len_errs) > 6 else ''}")
    fail = 1
else:
    print("lang: name/auth/descript/important all within the official limits OK")

# Pitfall 41 (V11 double gate): the review bot matches \bbeta\b across the whole file, any language
beta_hits = [ln for ln in text.splitlines() if re.search(r"\bbeta\b", ln, re.I)]
if beta_hits:
    print(f"lang: contains the word beta FAIL (V11 red line, {len(beta_hits)} lines)")
    fail = 1
else:
    print("lang: no beta wording OK")

# ---------- 3. appsettings-init.json ----------
try:
    cfg = json.loads((ROOT / "assets/appsettings-init.json").read_text(encoding="utf-8"))
    errs = []
    if cfg.get("IpAddresses") != "127.0.0.1":
        errs.append("IpAddresses != 127.0.0.1")
    if cfg.get("Port") != EXPECT_PORT:
        errs.append(f"Port != {EXPECT_PORT}")
    if cfg.get("BaseUrl") != "/kavita/":
        errs.append("BaseUrl != /kavita/")
    if errs:
        print(f"appsettings-init.json: wrong safety-net values FAIL {errs}")
        fail = 1
    else:
        print("appsettings-init.json: loopback/port/sub-path safety net correct OK")
except Exception as e:  # noqa: BLE001
    print(f"appsettings-init.json: invalid JSON FAIL ({e})")
    fail = 1

# ---------- 4. CRLF / BOM scan ----------
for p in sorted((ROOT / "assets").rglob("*")):
    if not p.is_file() or p.suffix not in {".ini", ".in", ".lang", ".conf",
                                           ".service", ".env", ".sh", ".html",
                                           ".js", ".css", ".svg", ".json"}:
        continue
    b = p.read_bytes()
    rel = p.relative_to(ROOT)
    if b.startswith(b"\xef\xbb\xbf"):
        print(f"{rel}: contains BOM FAIL")
        fail = 1
    if b"\r\n" in b or b"\r" in b:
        print(f"{rel}: contains CR FAIL")
        fail = 1
if fail == 0:
    print("line endings/BOM: all compliant OK")

# ---------- 5. Privacy policy (pitfall 45 / C3) ----------
pp = ROOT / "assets/privacy-policy.html"
if not pp.is_file() or "Privacy Policy" not in pp.read_text(encoding="utf-8")[:2000] \
        or "隐私政策" not in pp.read_text(encoding="utf-8"):
    print("privacy-policy.html: missing or not the bilingual template FAIL")
    fail = 1
else:
    print("privacy-policy.html: bilingual privacy policy present OK")

# ---------- 6. Icon integrity (pitfall 47: truncated download case) ----------
icon = ROOT / "assets/images/icons/kavita.svg"
try:
    tree = ET.parse(icon)
    root_el = tree.getroot()
    errs = []
    if not root_el.get("viewBox"):
        errs.append("missing viewBox")
    svg_txt = icon.read_text(encoding="utf-8")
    if "fill" not in svg_txt:
        errs.append("no fill colour")
    paths = root_el.iter("{http://www.w3.org/2000/svg}path")
    n_short = sum(1 for p_ in paths
                  if p_.get("d") is not None and len(p_.get("d")) < 10)
    if n_short:
        errs.append(f"{n_short} path d values suspiciously short (possible truncation)")
    if errs:
        print(f"icon: {errs} ✗")
        fail = 1
    else:
        print("icon: SVG parses + viewBox/fill/path complete OK")
except ET.ParseError as e:
    print(f"icon: XML parse error (possible truncation) FAIL ({e})")
    fail = 1

sys.exit(fail)
