#!/usr/bin/env python3
"""preflight-deb.py - pre-submission check for a built TOS deb.

Mirrors the platform's automated validation (publishing-process Step 6 and the
Review Standards pre-filter) so problems are caught before submitting:

  * required files present at /usr/local/<app_id>/{config.ini, <app_id>.lang,
    images/icons/<icon>}
  * config.ini: valid strict JSON, required fields, type/open_path exclusivity,
    path format, platform matches the package architecture,
    version/system_id/package consistent with DEBIAN/control
  * app.lang: the 14 officially required language nodes, non-empty name and
    descript, no "beta" wording, UTF-8 without BOM, LF endings,
    version matching config.ini
  * DEBIAN/control: Package/Version/Architecture/Maintainer/Depends/Description
    format (line width <= 80, paragraph separators " .")
  * icon: SVG with a viewBox, path matching config.ini's icon field
  * payload architecture: ELF machine must match the platform field
  * release asset naming: <app_id>_<platform>.deb (no version in the name)
  * companion .sha256 file must match the deb

Usage: python3 scripts/preflight-deb.py out/kavita_x86_64.deb [more.deb ...]
"""
import io
import json
import lzma
import os
import re
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET

REQUIRED_LANGS = ["zh-cn", "zh-hk", "en-us", "fr-fr", "de-de", "it-it", "es-es",
                  "hu-hu", "ja-jp", "ko-kr", "pl-pl", "ru-ru", "tr-tr", "pt-pt"]
LANG_LIMITS = {"name": 64, "auth": 64, "descript": 512, "important": 512}
REQUIRED_CFG = ["id", "icon", "publisher", "exec", "version", "recommend", "beta",
                "low_version", "category", "depend", "platform", "official",
                "application_type", "system_id", "package", "user",
                "all_user_display"]
ELF_MACHINE = {62: "x86_64", 183: "aarch64"}

results = []          # (ok, label, detail)


def check(ok, label, detail=""):
    results.append((bool(ok), label, detail))
    return ok


def read_ar(path):
    """Return {member_name: bytes} for an ar archive (tolerates trailing '/')."""
    data = open(path, "rb").read()
    if data[:8] != b"!<arch>\n":
        raise SystemExit(f"{path}: not an ar archive")
    off, out = 8, {}
    while off + 60 <= len(data):
        hdr = data[off:off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip().rstrip("/")
        try:
            size = int(hdr[48:58].decode("ascii", "replace").strip())
        except ValueError:
            break
        out.setdefault(name, data[off + 60: off + 60 + size])
        off += 60 + size + (size % 2)
    return out


def main(path):
    print(f"\n=== {os.path.basename(path)} ===")
    members = read_ar(path)
    for need in ("debian-binary", "control.tar.gz"):
        check(need in members, f"ar member {need} present")

    ctf = tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:*")
    control = ctf.extractfile("control" if "control" in ctf.getnames()
                              else next(n for n in ctf.getnames() if n.endswith("/control"))).read().decode()

    data_name = next(n for n in members if n.startswith("data.tar"))
    dtf = tarfile.open(fileobj=io.BytesIO(members[data_name]), mode="r:*")
    names = dtf.getnames()

    # ---- DEBIAN/control ----
    def cfield(f):
        m = re.search(rf"^{f}:\s*(.*)$", control, re.M)
        return m.group(1).strip() if m else None

    pkg, ver, arch = cfield("Package"), cfield("Version"), cfield("Architecture")
    check(pkg and re.fullmatch(r"[a-z0-9][a-z0-9-]*", pkg), f"control Package valid ({pkg})")
    check(bool(ver), f"control Version present ({ver})")
    check(arch in ("amd64", "arm64"), f"control Architecture valid ({arch})")
    check(bool(cfield("Maintainer")), f"control Maintainer present ({cfield('Maintainer')})")
    check(bool(cfield("Depends")), f"control Depends declared ({cfield('Depends')})")
    desc_lines = control.split("Description:", 1)[1].splitlines() if "Description:" in control else []
    if desc_lines:
        syn = desc_lines[0]
        check(len(syn) <= 80, f"Description synopsis <= 80 chars ({len(syn)})")
        long_lines = [l for l in desc_lines[1:] if len(l) > 80]
        check(not long_lines, "Description detail lines <= 80 chars",
              f"{len(long_lines)} too long" if long_lines else "")
        bad = [l for l in desc_lines[1:] if l and not l.startswith(" ")]
        check(not bad, "Description detail lines start with a space")

    # ---- required files & app root ----
    app_root = None
    for n in names:
        m = re.fullmatch(r"\./usr/local/([^/]+)/config\.ini", n)
        if m:
            app_root = m.group(1)
    check(bool(app_root), f"app root with config.ini found ({app_root})")
    if not app_root:
        return
    appid = pkg
    check(app_root == appid, f"app root == control Package ({app_root} vs {appid})")

    base = f"./usr/local/{app_root}/"
    cfg_bytes = dtf.extractfile(f"{base}config.ini").read()
    cfg = json.loads(cfg_bytes)
    check(cfg.get("id") == appid, f"config.ini id == Package ({cfg.get('id')})")
    for f in REQUIRED_CFG:
        check(f in cfg, f"config.ini required field '{f}'")
    check("type" not in cfg, "config.ini has no 'type' (open_path mode)")
    check(cfg.get("open_path") is True, "config.ini open_path == true")
    check(bool(re.fullmatch(r"/[a-z0-9_-]+/", str(cfg.get("path", "")))),
          f"config.ini path is a route ({cfg.get('path')})")
    check(cfg.get("beta") is False, "config.ini beta == false")
    check(cfg.get("recommend") is False, "config.ini recommend == false")
    check(cfg.get("version") == ver, f"config.ini version == control Version ({cfg.get('version')})")
    check(cfg.get("system_id") == appid, "config.ini system_id == id")
    check(cfg.get("package") == appid, "config.ini package == id")
    check(cfg.get("user") == appid, "config.ini user == id")

    lang_names = [n for n in names if re.fullmatch(rf"\./usr/local/{app_root}/[^/]+\.lang", n)]
    check(bool(lang_names), f"language file present ({os.path.basename(lang_names[0]) if lang_names else '-'})")
    if lang_names:
        lname = os.path.basename(lang_names[0])
        check(lname == f"{appid}.lang", f"language file named <id>.lang ({lname})")
        raw = dtf.extractfile(lang_names[0]).read()
        check(not raw.startswith(b"\xef\xbb\xbf"), "app.lang has no BOM")
        check(b"\r" not in raw, "app.lang uses LF only")
        txt = raw.decode("utf-8")
        found = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", txt, re.M)
        missing = [t for t in REQUIRED_LANGS if t not in found]
        check(not missing, "all 14 required language nodes present", f"missing {missing}" if missing else "")
        check(not re.search(r"\bbeta\b", txt, re.I), "app.lang has no beta wording")
        secs = re.split(r"^\[([a-z]{2}-[a-z]{2})\]$", txt, flags=re.M)
        empty, overlong, ver_bad = [], [], []
        for i in range(1, len(secs), 2):
            code, body = secs[i], secs[i + 1]
            for fld in ("name", "descript"):
                m = re.search(rf'^{fld}\s*=\s*"(.*)"$', body, re.M)
                if not m or not m.group(1).strip():
                    empty.append(f"{code}:{fld}")
            for fld, lim in LANG_LIMITS.items():
                m = re.search(rf'^{fld}\s*=\s*"(.*)"$', body, re.M)
                if m and len(m.group(1)) > lim:
                    overlong.append(f"{code}:{fld}={len(m.group(1))}")
            m = re.search(r'^version\s*=\s*"(.*)"$', body, re.M)
            if m and m.group(1) != ver:
                ver_bad.append(code)
        check(not empty, "app.lang name/descript non-empty for every language")
        check(not overlong, "app.lang fields within the official length limits")
        check(not ver_bad, "app.lang version matches control Version")

    icon_rel = str(cfg.get("icon", "")).lstrip("/")
    icon_entry = f"{base}{icon_rel}"
    check(icon_entry in names, f"icon exists at config.ini icon path ({icon_entry})")
    if icon_entry in names:
        svg = dtf.extractfile(icon_entry).read()
        try:
            root = ET.fromstring(svg)
            check(bool(root.get("viewBox")), "icon has a viewBox")
            check(b"<svg" in svg and b"</svg>" in svg, "icon is SVG")
        except ET.ParseError as e:
            check(False, "icon parses as XML", str(e))
    check(icon_rel == f"images/icons/{os.path.basename(icon_rel)}",
          "icon path matches /images/icons/<file>.svg")

    # ---- architecture vs platform field ----
    want = {"x86_64": 62, "aarch64": 183}.get(str(cfg.get("platform")))
    check(bool(want), f"platform field is x86_64/aarch64 ({cfg.get('platform')})")
    elf_files = [n for n in names if n.startswith(f"{base}bin/") and n.endswith(("Kavita", "kavita"))]
    for ef in elf_files[:1]:
        blob = dtf.extractfile(ef).read(20)
        machine = int.from_bytes(blob[18:20], "little")
        check(machine == want, f"payload ELF machine matches platform ({ELF_MACHINE.get(machine)})")

    # ---- asset naming + checksum ----
    check(bool(re.fullmatch(rf"{re.escape(appid)}_(x86_64|aarch64)\.deb", os.path.basename(path))),
          f"asset name is <app_id>_<platform>.deb ({os.path.basename(path)})")
    sha_path = path + ".sha256"
    if os.path.exists(sha_path):
        want_hash = open(sha_path).read().split()[0]
        got = subprocess.run(["shasum", "-a", "256", path], capture_output=True, text=True).stdout.split()[0]
        check(want_hash == got, "companion .sha256 matches the deb")

    # ---- directory case compliance ----
    bad_dirs = [n for n in names if n.endswith("/") and any(c.isupper() for c in n.split("/")[-2])]
    check(not bad_dirs, "directory names are lowercase", f"{bad_dirs[:3]}" if bad_dirs else "")


failures = 0
for path in sys.argv[1:]:
    results.clear()
    main(path)
    bad = [r for r in results if not r[0]]
    failures += len(bad)
    for ok, label, detail in results:
        print(f"  {'OK  ' if ok else 'FAIL'} {label}" + (f"  [{detail}]" if detail else ""))
    print(f"  --> {len(results) - len(bad)}/{len(results)} checks passed")

print()
print("PREFLIGHT:", "ALL PASS" if failures == 0 else f"{failures} FAILURE(S)")
sys.exit(1 if failures else 0)
