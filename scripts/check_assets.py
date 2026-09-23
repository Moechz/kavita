#!/usr/bin/env python3
"""check_assets.py — 上架前的资产静态自检（Makefile check 调用）

按 TOS 7 应用中心规范校验：
  1. assets/config.ini.in 是合法 JSON（渲染 @@VERSION@@ 等占位符后）
  2. assets/kavita.lang 含 23 语超集（真机 14 语 + 官方 14 语口径并集），
     UTF-8 无 BOM，LF 行尾；全文不得出现 beta 字样（审核 V11 双重门禁）
  3. assets/appsettings-init.json 是合法 JSON 且安全兜底三值正确
     （IpAddresses=127.0.0.1 / Port=8500 / BaseUrl=/kavita/）
  4. assets/ 下所有文本资产无 CRLF / BOM
  5. 隐私政策存在且可解析（审核 C3 必备资产，坑 45）
  6. 图标 SVG 完整性：XML 可解析 + viewBox + fill（坑 47 截断实锤）
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

# 与 config.env 的 APP_PORT 保持同步（此处为静态兜底断言，改端口时同步改这里）
EXPECT_PORT = 8500

# ---------- 1. config.ini.in ----------
raw = (ROOT / "assets/config.ini.in").read_text(encoding="utf-8")
rendered = (raw.replace("@@VERSION@@", "0.0.0")
              .replace("@@PUBLISHER@@", "x")
              .replace("@@PLATFORM@@", "x86_64"))
try:
    json.loads(rendered)
    print("config.ini.in: JSON 合法 ✓")
except Exception as e:  # noqa: BLE001
    print(f"config.ini.in: JSON 非法 ✗ ({e})")
    fail = 1

# ---------- 2. lang ----------
lang_path = ROOT / "assets/kavita.lang"
data = lang_path.read_bytes()
if data.startswith(b"\xef\xbb\xbf"):
    print("lang: 含 BOM ✗")
    fail = 1
text = data.decode("utf-8")
found = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", text, re.M)
missing = [t for t in REQUIRED_LANGS if t not in found]
if missing:
    print(f"lang: 缺少语言节 ✗ {missing}")
    fail = 1
else:
    print(f"lang: 23 语超集齐全 ✓（共 {len(found)} 节）")

# 官文 app.lang 长度硬上限（字符）：name64 / auth64 / descript512 / important512
LANG_LIM = {"name": 64, "auth": 64, "descript": 512, "important": 512}
len_errs = []
_secs = re.split(r"^\[([a-z]{2}-[a-z]{2})\]$", text, flags=re.M)
for _i in range(1, len(_secs), 2):
    _code, _body = _secs[_i], _secs[_i + 1]
    for _f, _lim in LANG_LIM.items():
        _m = re.search(rf'^{_f}\s*=\s*"(.*)"$', _body, re.M)
        _v = _m.group(1) if _m else ""
        if not _v:
            len_errs.append(f"{_code}:{_f} 为空")
        elif len(_v) > _lim:
            len_errs.append(f"{_code}:{_f}={len(_v)}>{_lim}")
if len_errs:
    print(f"lang: 字段长度/空值不合规 ✗ {len_errs[:6]}{' …' if len(len_errs) > 6 else ''}")
    fail = 1
else:
    print("lang: name/auth/descript/important 长度均在官方上限内 ✓")

# 坑 41（V11 双重门禁）：审核机器全文匹配 \bbeta\b，不分语言不分字段
beta_hits = [ln for ln in text.splitlines() if re.search(r"\bbeta\b", ln, re.I)]
if beta_hits:
    print(f"lang: 含 beta 字样 ✗（V11 红线，共 {len(beta_hits)} 行）")
    fail = 1
else:
    print("lang: 无 beta 字样 ✓")

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
        print(f"appsettings-init.json: 安全兜底值不符 ✗ {errs}")
        fail = 1
    else:
        print("appsettings-init.json: 回环/端口/子路径兜底正确 ✓")
except Exception as e:  # noqa: BLE001
    print(f"appsettings-init.json: JSON 非法 ✗ ({e})")
    fail = 1

# ---------- 4. CRLF / BOM 扫描 ----------
for p in sorted((ROOT / "assets").rglob("*")):
    if not p.is_file() or p.suffix not in {".ini", ".in", ".lang", ".conf",
                                           ".service", ".env", ".sh", ".html",
                                           ".js", ".css", ".svg", ".json"}:
        continue
    b = p.read_bytes()
    rel = p.relative_to(ROOT)
    if b.startswith(b"\xef\xbb\xbf"):
        print(f"{rel}: 含 BOM ✗")
        fail = 1
    if b"\r\n" in b or b"\r" in b:
        print(f"{rel}: 含 CR ✗")
        fail = 1
if fail == 0:
    print("行尾/BOM: 全部合规 ✓")

# ---------- 5. 隐私政策（坑 45/C3）----------
pp = ROOT / "assets/privacy-policy.html"
if not pp.is_file() or "Privacy Policy" not in pp.read_text(encoding="utf-8")[:2000] \
        or "隐私政策" not in pp.read_text(encoding="utf-8"):
    print("privacy-policy.html: 缺失或非双语模板 ✗")
    fail = 1
else:
    print("privacy-policy.html: 双语隐私政策存在 ✓")

# ---------- 6. 图标完整性（坑 47：下载截断实锤）----------
icon = ROOT / "assets/images/icons/kavita.svg"
try:
    tree = ET.parse(icon)
    root_el = tree.getroot()
    errs = []
    if not root_el.get("viewBox"):
        errs.append("缺 viewBox")
    svg_txt = icon.read_text(encoding="utf-8")
    if "fill" not in svg_txt:
        errs.append("无 fill 色")
    paths = root_el.iter("{http://www.w3.org/2000/svg}path")
    n_short = sum(1 for p_ in paths
                  if p_.get("d") is not None and len(p_.get("d")) < 10)
    if n_short:
        errs.append(f"{n_short} 个 path d 数据异常短（疑似截断）")
    if errs:
        print(f"icon: {errs} ✗")
        fail = 1
    else:
        print("icon: SVG 可解析 + viewBox/fill/path 完整 ✓")
except ET.ParseError as e:
    print(f"icon: XML 解析失败（疑似截断）✗ ({e})")
    fail = 1

sys.exit(fail)
