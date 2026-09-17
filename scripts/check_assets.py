#!/usr/bin/env python3
"""check_assets.py — 上架前的资产静态自检（Makefile check 调用）

按 TOS 7 应用中心规范校验：
  1. assets/config.ini.in 是合法 JSON（渲染 @@VERSION@@ 等占位符后）
  2. assets/kavita.lang 含 23 语超集（真机 14 语 + 官方 14 语口径并集），
     UTF-8 无 BOM，LF 行尾
  3. assets/appsettings-init.json 是合法 JSON 且安全兜底三值正确
     （IpAddresses=127.0.0.1 / Port=8500 / BaseUrl=/kavita/）
  4. assets/ 下所有文本资产无 CRLF / BOM
"""
import json
import re
import sys
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

sys.exit(fail)
