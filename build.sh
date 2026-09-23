#!/usr/bin/env bash
# ============================================================
# build.sh - package Kavita as a TOS 7 App Center
# compliant deb (WebUI External Open / new-tab mode) on macOS or Linux
#
# Specification reference: https://help.terra-master.com/developer/development-docs/
#   - Deb Development Specification (layout / config.ini / nginx / systemd / lifecycle)
#   - Package Specification (three-way version consistency, asset naming)
#
# Mode (the navidrome-style prefix-preserving proxy):
#   Kavita natively supports sub-path deployment (appsettings.json BaseUrl +
#   Startup.UsePathBase + SPA <base href>), so nginx forwards /kavita/ verbatim
#   instead of stripping the prefix; the app works natively under the sub-path and the reader/API/
#   OPDS/SignalR all stay consistent.
#   Kavita has no CLI options and no environment-variable overrides (upstream clears the env source),
#   so the safety net lives in the config/appsettings.json template (the Port/IpAddresses/BaseUrl
#   values are asserted by the verify stage) reached through the bin/config -> /var/lib/kavita symlink;
#   on first install postinst drops appsettings-init.json and the app renames it
#   and generates the JWT TokenKey on first start.
#
# Artifacts (out/):
#   kavita_<platform>.deb           the single deb per architecture
#                                   (platform = x86_64 / aarch64; the platform
#                                   validator requires this exact name)
#   kavita_<platform>.deb.sha256    checksum file (required for submission)
# (single artifact per architecture: no second versioned copy)
#
# Stages: fetch -> stage -> verify -> deb
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# Allow `TARGET_ARCH=arm64 ./build.sh` to override the config.env default
# (snapshot the process environment first, restore it after sourcing config.env)
ENV_TARGET_ARCH=${TARGET_ARCH:-}
# shellcheck source=config.env
. "$SCRIPT_DIR/config.env"
if [ -n "$ENV_TARGET_ARCH" ]; then
  TARGET_ARCH=$ENV_TARGET_ARCH
fi

BUILD_DIR="$SCRIPT_DIR/build"
DL_DIR="$BUILD_DIR/downloads"
STAGE_DIR="$BUILD_DIR/pkgroot"
OUT_DIR="$SCRIPT_DIR/out"
ASSETS_DIR="$SCRIPT_DIR/assets"

# Full version = upstream version-packaging iteration (e.g. 0.9.1.4-1)
# Must match in three places: config.ini / DEBIAN/control / .lang
VERSION_FULL="${KAVITA_VERSION}-${PKG_RELEASE}"

# ---------------- target platform (TOS / NAS side) ----------------
case "$TARGET_ARCH" in
  amd64)
    K_ARCH="x64"
    TOS_PLATFORM="x86_64"
    ELF_ARCH="x86-64"
    PINNED_SHA="$KAVITA_X64_SHA256"
    ;;
  arm64)
    K_ARCH="arm64"
    TOS_PLATFORM="aarch64"
    ELF_ARCH="ARM aarch64"
    PINNED_SHA="$KAVITA_ARM64_SHA256"
    ;;
  *)
    echo "error: unknown TARGET_ARCH=$TARGET_ARCH (supported: amd64 / arm64)" >&2
    exit 1
    ;;
esac

TAG="v$KAVITA_VERSION"
# Review item V6 (automatic rejection): binaries are built from the upstream source tag by public CI
# (Moechz/kavita build-upstream.yml, mirroring the upstream release-workflow.yml verbatim),
# instead of downloading the upstream prebuilt tarball; the tarball carries BUILD-INFO
# provenance data and verify asserts built_from=source.
RELEASE_BASE="https://github.com/$SELF_BUILD_REPO/releases/download/build-$TAG"
TGZ="kavita-linux-${K_ARCH}.tar.gz"
# Upstream publishes no checksums file -> config.env pins plus a local lock file
LOCK_FILE="$DL_DIR/sha256.lock"
# Artifact naming (official requirement, re-confirmed 2026-09 after a validator
# rejection): the release asset must be "<app_id>_<platform>.deb" with the TOS
# platform name (x86_64 / aarch64) and no version in the file name. The version
# is expressed by the release tag, which must equal config.ini.version.
# Note: the App Center manual-install page itself accepts any file name, but the
# submission validator parses <app_id> from the asset name - keep this scheme.
# Release/submission asset name: the platform parses <app_id> from the asset
# file name and requires EXACTLY "<app_id>_<platform>.deb" (platform = the
# config.ini platform value: x86_64 / aarch64, no version - the version lives
# in the release tag). Non-compliant names are rejected by the automated
# validator (empirically: every published sibling package uses this scheme).
DEB_FILE="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"

MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest-file> (retries + resume)
  local url=$1 dest=$2 attempt=0
  if [ -s "$dest" ]; then
    log "cached: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "download: $(basename "$dest")"
  while [ $attempt -lt 8 ]; do
    attempt=$((attempt + 1))
    if curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
         --connect-timeout 30 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return 0
    fi
    rm -f "$dest.part"  # restart from scratch when the server does not support resume
    warn "download failed (attempt $attempt): $(basename "$dest"); retrying in 10s..."
    sleep 10
  done
  die "download failed: $url"
}

sha256_of() { # sha256_of <file> -> 64-char hash (macOS/Linux compatible)
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# sha256 anchoring: prefer the manual pin in config.env, otherwise the local lock (guards against swapped caches)
verify_sha256() { # verify_sha256 <file-full-path> <pinned-value>; lock key is the basename
  local f=$1 base pinned=${2:-} got locked
  base=$(basename "$f")
  got=$(sha256_of "$f")
  if [ -n "$pinned" ]; then
    [ "$got" = "$pinned" ] || die "sha256 mismatch against the config.env pin: $base (want=$pinned got=$got)"
    log "  ok: $base (config.env pin verified)"
    return 0
  fi
  locked=$(grep -a "^$base " "$LOCK_FILE" 2>/dev/null | awk '{print $2}' || true)
  if [ -n "$locked" ]; then
    [ "$got" = "$locked" ] || die "sha256 mismatch against the local lock: $base (lock=$locked got=$got; delete the lock and re-run if this is expected)"
    log "  ok: $base (lock verified)"
  else
    mkdir -p "$DL_DIR"
    echo "$base $got" >> "$LOCK_FILE"
    warn "sha256 recorded in $LOCK_FILE (pin it in config.env as KAVITA_*_SHA256): $got"
  fi
}

normalize_text() { # specification: text files must use LF endings and UTF-8 without BOM (cleaned at build time)
  python3 - "$@" <<'PYEOF'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f:
        data = f.read()
    if data.startswith(b'\xef\xbb\xbf'):
        data = data[3:]
    data = data.replace(b'\r\n', b'\n').replace(b'\r', b'\n')
    with open(p, 'wb') as f:
        f.write(data)
PYEOF
}

# ============================================================
# Stage: fetch
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR"

  # 1. Kavita runtime (built from upstream source by public CI; self-contained .NET incl. wwwroot/I18N)
  fetch "$RELEASE_BASE/$TGZ" "$DL_DIR/$TGZ"

  # 1b. Double verification against SHA256SUMS (pitfall 48, trap 3): release list x config.env pin
  #     Two independent sources, guarding against swapped assets or corrupt downloads; a cached
  #     prebuilt tarball fails here - delete build/downloads/kavita-linux-*.tar.gz and re-run
  fetch "$RELEASE_BASE/SHA256SUMS" "$DL_DIR/SHA256SUMS-$KAVITA_VERSION"
  local sums_line
  sums_line=$(grep -a " $TGZ\$" "$DL_DIR/SHA256SUMS-$KAVITA_VERSION" | head -1 | awk '{print $1}')
  [ -n "$sums_line" ] || die "$TGZ not found in SHA256SUMS (incomplete release assets?)"
  [ "$(sha256_of "$DL_DIR/$TGZ")" = "$sums_line" ] \
    || die "$TGZ does not match the release SHA256SUMS (if stale, delete build/downloads/kavita-linux-*.tar.gz and re-run)"
  log "  ok: $TGZ (release SHA256SUMS double verification passed)"

  # 2. Upstream LICENSE fallback prefetch (only used when the tarball does not ship LICENSE;
  #    the member name is re-detected in the stage phase so stage can run standalone)
  if ! tar tzf "$DL_DIR/$TGZ" 2>/dev/null | grep -qiE '(^|/)LICENSE$'; then
    fetch "https://raw.githubusercontent.com/Kareadita/Kavita/$TAG/LICENSE" "$DL_DIR/LICENSE"
  fi

  # 3. sha256 verification (pin/lock logic in verify_sha256)
  log "verifying sha256..."
  verify_sha256 "$DL_DIR/$TGZ" "$PINNED_SHA"
}

# ============================================================
# Stage: stage - assemble the deb filesystem tree (official layout)
# ============================================================
stage_stage() {
  [ -s "$DL_DIR/$TGZ" ] || die "missing $TGZ; run ./build.sh fetch first"

  local APP="$STAGE_DIR/usr/local/$APP_ID"
  log "assembling filesystem tree: $STAGE_DIR (official /usr/local/$APP_ID layout)"
  rm -rf "$STAGE_DIR"
  mkdir -p "$APP/bin"
  mkdir -p "$APP/config-template"
  mkdir -p "$APP/images/icons"
  mkdir -p "$APP/nginx"
  mkdir -p "$APP/init.d"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"

  # Runtime tree: everything from the tarball except config/ goes into bin/
  #  (Kavita resolves everything against the CWD: wwwroot/I18N/Assets/EmailTemplates must sit next to
  #  the process CWD, so the whole runtime tree lives under bin/ and WorkingDirectory points there)
  # The tarball may have a top-level Kavita/ directory or be flat; detect it automatically
  log "  + bin/ (upstream $KAVITA_VERSION runtime tree, upstream config/ removed)"
  local top prefix_args=()
  top=$(tar tzf "$DL_DIR/$TGZ" | head -1 | cut -d/ -f1)
  if tar tzf "$DL_DIR/$TGZ" | grep -qv "^$top/\|^$top$"; then
    # Flat layout (mixed files/directories at the top level)
    tar xzf "$DL_DIR/$TGZ" -C "$APP/bin" \
      --exclude='config' --exclude='config/*'
  else
    # Single top-level directory
    tar xzf "$DL_DIR/$TGZ" -C "$APP/bin" --strip-components=1 \
      --exclude="$top/config" --exclude="$top/config/*"
  fi
  rm -rf "$APP/bin/config"
  [ -f "$APP/bin/Kavita" ] || die "no Kavita executable inside the tarball (layout changed? check $DL_DIR/$TGZ)"
  # The upstream tarball stores the apphost as 0644 (measured), so the executable bit must be added;
  # createdump gets it too (used to write core dumps on crashes); other files keep upstream permissions
  chmod 0755 "$APP/bin/Kavita"
  [ -x "$APP/bin/createdump" ] && chmod 0755 "$APP/bin/createdump" || true
  [ -x "$APP/bin/Kavita" ] || die "Kavita still not executable after chmod (unexpected)"

  # Pre-write the SPA base href for the sub-path (part of the prefix-preserving scheme):
  # On startup the app writes BaseUrl back into wwwroot/index.html's <base href>;
  # writing the same value at build time keeps behaviour correct if the write fails in the read-only sandbox
  log "  + bin/wwwroot/index.html <base href> -> /$APP_ID/"
  python3 - "$APP/bin/wwwroot/index.html" "/$APP_ID/" <<'PYEOF'
import re, sys
p, base = sys.argv[1], sys.argv[2]
html = open(p, encoding='utf-8').read()
new, n = re.subn(r'<base\s+href="[^"]*"\s*/?>',
                 f'<base href="{base}">', html, count=1)
if n == 0 and '<base' not in html:
    new, m = re.subn(r'(<head[^>]*>)', lambda mo: mo.group(1) + f'<base href="{base}">',
                     html, count=1)
    if m == 0:
        raise SystemExit('wwwroot/index.html has neither <base> nor <head>; cannot inject the base href')
open(p, 'w', encoding='utf-8').write(new)
PYEOF

  # config symlink: Kavita state = $(CWD)/config/*, pointed at the data volume
  log "  + bin/config -> /var/lib/$APP_ID (state directory symlinked onto the data volume)"
  ln -s "/var/lib/$APP_ID" "$APP/bin/config"

  # config.ini (strict JSON; @@...@@ placeholders rendered)
  log "  + config.ini（External Open: open_path=true, path=/$APP_ID/）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # Language file (name must equal the app id; 23-language superset covering both the device-tested and documented 14)
  log "  + $APP_ID.lang (23 languages)"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # Icon (official logo, viewBox 0 0 64 64, brand circle; file name must equal the app id)
  log "  + images/icons/$APP_ID.svg"
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # nginx route: nginx/ inside the app directory satisfies the TOS layout, and a real dpkg-managed file goes to
  # /etc/nginx/conf.d (the dual-placement pattern verified by metube and navidrome)
  log "  + nginx/ + /etc/nginx/conf.d/ (loopback proxy to 127.0.0.1:$APP_PORT, prefix preserved)"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # systemd service: init.d/ satisfies the TOS layout, and a real dpkg-managed file goes to
  # /etc/systemd/system (dual placement; systemd loads it directly, no postinst copy needed)
  log "  + init.d/ + /etc/systemd/system/"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$APP/init.d/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service"

  # webui.bz2 (required for WebUI apps; must contain an openable .html. Kavita's frontend is embedded in
  # the runtime tree and served through the nginx route, so this is the required placeholder frontend)
  log "  + webui.bz2 (placeholder frontend redirecting to /$APP_ID/)"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@APP_PORT@@|$APP_PORT|g" \
      "$ASSETS_DIR/webui/index.html" > "$WEBUI_DIR/index.html"
  # Pitfall 8 (macOS pollution): bsdtar stores extended attributes as AppleDouble ._ entries inside archives.
  # Belt and braces: COPYFILE_DISABLE=1 plus deleting ._ files before archiving
  find "$WEBUI_DIR" -name '._*' -delete 2>/dev/null || true
  # Pitfall 46 (S11 warning): nested archive entries must be owned by root:root; macOS bsdtar has no
  # --owner flag, so re-pack with python tarfile (uid/gid=0, uname/gname=root, mtime=0)
  python3 - "$WEBUI_DIR" "$APP/webui.bz2" <<'PYEOF'
import os, sys, tarfile
src, dest = sys.argv[1], sys.argv[2]
with tarfile.open(dest, "w:bz2") as tf:
    for name in sorted(os.listdir(src)):
        p = os.path.join(src, name)
        if not os.path.isfile(p):
            continue
        ti = tf.gettarinfo(p, arcname=name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        with open(p, "rb") as f:
            tf.addfile(ti, f)
PYEOF

  # Kavita configuration template (source for the appsettings-init.json dropped by postinst on first install;
  # Kavita renames it to appsettings.json and generates the JWT TokenKey on first start)
  log "  + config-template/appsettings-init.json (Port=$APP_PORT / loopback / BaseUrl=/$APP_ID/)"
  sed -e "s|@@APP_PORT@@|$APP_PORT|g" \
      "$ASSETS_DIR/appsettings-init.json" > "$APP/config-template/appsettings-init.json"

  # Configuration template (shipped as .example; postinst copies it to the real env on first install; upgrades never overwrite)
  log "  + $APP_ID.env.example configuration template"
  cp "$ASSETS_DIR/$APP_ID.env" "$APP/$APP_ID.env.example"

  # Privacy policy (required by review item C3): dual placement in the package + exact nginx route (pitfall 45)
  log "  + privacy-policy.html (bilingual, exact nginx route /$APP_ID/privacy-policy.html)"
  cp "$ASSETS_DIR/privacy-policy.html" "$APP/privacy-policy.html"

  # Binary provenance notes (audit material for review item V6; pitfalls 31/32/43)
  # Note: the TOS system dpkg config excludes /usr/share/doc/* (only copyright and
  # changelog.* are exempt), so files placed there are dropped by the platform; keep them in the app directory
  log "  + PROVENANCE.md (source-build audit chain -> /usr/local/$APP_ID/)"
  cp "$ASSETS_DIR/PROVENANCE.md" "$APP/PROVENANCE.md"

  # Documentation (match the LICENSE member name exactly in the tar listing rather than guessing; fall back to the prefetched copy)
  local license_member
  license_member=$(tar tzf "$DL_DIR/$TGZ" 2>/dev/null | grep -iE '(^|/)LICENSE$' | head -1 || true)
  if [ -n "$license_member" ]; then
    tar xzOf "$DL_DIR/$TGZ" "$license_member" > "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  else
    cp "$DL_DIR/LICENSE" "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"
  fi
  {
    echo "$APP_ID ($VERSION_FULL) TOS7; urgency=medium"
    echo ""
    echo "  * Packaged from Kavita upstream $KAVITA_VERSION"
    echo "  * Runtime built from upstream source by public CI (double sha256 anchoring); self-contained .NET, no runtime deps"
    echo "  * WebUI External Open: opened in a new tab via the /$APP_ID/ route; backend listens on loopback only"
    echo "  * Sub-path supported natively via BaseUrl=/$APP_ID/ (SPA base href pre-written at build time)"
    echo "  * State directory placed on /var/lib/$APP_ID through the bin/config symlink"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # Specification cleanup: LF endings + BOM removal (all text assets; the binary runtime tree is untouched)
  log "  normalising line endings (LF) and BOM"
  normalize_text \
    "$APP/config.ini" "$APP/$APP_ID.lang" \
    "$APP/nginx/$APP_ID.conf" \
    "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
    "$APP/init.d/"*.service \
    "$STAGE_DIR/etc/systemd/system/"*.service \
    "$APP/config-template/appsettings-init.json" \
    "$APP/privacy-policy.html" \
    "$APP/PROVENANCE.md" \
    "$APP/"*.example \
    "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"

  # Strip macOS extended attributes so they cannot pollute the tar (AppleDouble / quarantine)
  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" -name '._*' -delete 2>/dev/null || true
  find "$STAGE_DIR" -name '.DS_Store' -delete 2>/dev/null || true

  log "assembly complete"
}

# ============================================================
# Stage: verify - architecture and specification assertions
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "not assembled yet; run ./build.sh stage first"
  local fail=0

  log "checking required paths..."
  local p
  for p in "$APP/config.ini" "$APP/$APP_ID.lang" \
           "$APP/images/icons/$APP_ID.svg" \
           "$APP/nginx/$APP_ID.conf" \
           "$APP/init.d/$APP_ID.service" \
           "$STAGE_DIR/etc/systemd/system/$APP_ID.service" \
           "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
           "$APP/bin/Kavita" \
           "$APP/webui.bz2" \
           "$APP/$APP_ID.env.example" \
           "$APP/config-template/appsettings-init.json" \
           "$APP/privacy-policy.html" \
           "$APP/PROVENANCE.md" \
           "$APP/bin/BUILD-INFO" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"; do
    [ -e "$p" ] || { warn "missing: ${p#$STAGE_DIR/}"; fail=1; }
  done

  log "checking config.ini (JSON validity / mutually exclusive fields / version consistency)..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" "$APP_USER" <<'PYEOF' || fail=1
import json, sys
cfg_path, want_ver, want_plat, app_id, app_user = sys.argv[1:6]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id mismatch")
if cfg.get("package") != app_id: errs.append("package mismatch")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
# WebUI External Open: open_path=true and type must be absent; path=/<id>/
if cfg.get("open_path") is not True: errs.append("open_path must be true")
if "type" in cfg: errs.append("type must not be present (mutually exclusive with open_path)")
if cfg.get("path") != f"/{app_id}/": errs.append(f"path must be /{app_id}/")
if cfg.get("user") != app_user: errs.append(f"user must be {app_user}")
if cfg.get("recommend") is not False: errs.append("recommend must be false when submitting")
for e in errs:
    print(f"    check failed: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "checking .lang (23-language superset + official length limits + beta gate)..."
  local lang_missing
  lang_missing=$(python3 - "$APP/$APP_ID.lang" "$VERSION_FULL" <<'PYEOF'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
want_ver = sys.argv[2]
required = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es",
            "hu-hu","ja-jp","ko-kr","pl-pl","ru-ru","tr-tr","pt-pt",
            "ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl","sv-se",
            "th-th","vi-vn"]
errs = [t for t in required if f"[{t}]" not in text]
# Official app.lang hard limits (characters): name 64 / auth 64 / descript 512 / important 512
LIM = {"name": 64, "auth": 64, "descript": 512, "important": 512}
secs = re.split(r'^\[([a-z]{2}-[a-z]{2})\]$', text, flags=re.M)
for i in range(1, len(secs), 2):
    code, body = secs[i], secs[i+1]
    for fld, lim in LIM.items():
        m = re.search(rf'^{fld}\s*=\s*"(.*)"$', body, re.M)
        v = m.group(1) if m else ""
        if not v:
            errs.append(f"{code}:{fld} empty")
        elif len(v) > lim:
            errs.append(f"{code}:{fld}={len(v)}>{lim}")
    # Three-way version consistency (config.ini / control / app.lang)
    m = re.search(r'^version\s*=\s*"(.*)"$', body, re.M)
    if m and m.group(1) != want_ver:
        errs.append(f"{code}:version={m.group(1)}!={want_ver}")
    if re.search(r'\bbeta\b', body, re.I):
        errs.append(f"{code}: contains beta")
print(",".join(errs))
PYEOF
)
  [ -z "$lang_missing" ] || { warn "lang check failed: $lang_missing"; fail=1; }

  log "checking the appsettings template (loopback / port / sub-path safety net)..."
  python3 - "$APP/config-template/appsettings-init.json" "$APP_PORT" "$APP_ID" <<'PYEOF' || fail=1
import json, sys
cfg = json.load(open(sys.argv[1]))
port, app_id = sys.argv[2], sys.argv[3]
errs = []
if cfg.get("IpAddresses") != "127.0.0.1": errs.append("IpAddresses must be 127.0.0.1")
if cfg.get("Port") != int(port): errs.append(f"Port must be {port}")
if cfg.get("BaseUrl") != f"/{app_id}/": errs.append(f"BaseUrl must be /{app_id}/")
if not str(cfg.get("TokenKey","")).startswith("super secret unguessable key"):
    errs.append("TokenKey must keep the upstream placeholder (generated by Kavita on first start)")
for e in errs:
    print(f"    check failed: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "checking the SPA base href (needed to resolve frontend assets under the sub-path)..."
  grep -q "<base href=\"/$APP_ID/\">" "$APP/bin/wwwroot/index.html" \
    || { warn "wwwroot/index.html lacks <base href=\"/$APP_ID/\">"; fail=1; }

  log "checking the config symlink (state must live on the data volume)..."
  [ -L "$APP/bin/config" ] || { warn "bin/config must be a symlink"; fail=1; }
  [ "$(readlink "$APP/bin/config")" = "/var/lib/$APP_ID" ] \
    || { warn "bin/config must point at /var/lib/$APP_ID (currently: $(readlink "$APP/bin/config" 2>/dev/null || echo none))"; fail=1; }
  [ -e "$APP/bin/config" ] && warn "note: the data volume directory not existing here is expected (created on the target)"

  log "checking the systemd unit (no Restart / StartLimit required / no variable expansion in ExecStart)..."
  local svc
  for svc in "$APP/init.d/"*.service \
             "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "not a systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "Restart is forbidden by the specification: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "variable expansion in ExecStart is forbidden (caused 502s everywhere): $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "missing StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "missing StartLimitIntervalSec: $svc"; fail=1; }
    grep -q "^User=$APP_USER" "$svc" || { warn "User=$APP_USER required: $svc"; fail=1; }
    grep -q "^WorkingDirectory=/usr/local/$APP_ID/bin$" "$svc" \
      || { warn "WorkingDirectory=/usr/local/$APP_ID/bin required: $svc"; fail=1; }
    grep -q '^ReadWritePaths=/var/lib/' "$svc" \
      || { warn "ReadWritePaths=/var/lib/$APP_ID required: $svc"; fail=1; }
  done
  # init.d/ may hold exactly one main unit named after system_id (extra units hang the App Center install)
  local n_units
  n_units=$(find "$APP/init.d" -name '*.service' | wc -l | tr -d ' ')
  [ "$n_units" = "1" ] || { warn "init.d/ must hold exactly 1 service (found $n_units; pitfall 11)"; fail=1; }

  log "checking nginx (prefix-preserving proxy + WebSocket + loopback)..."
  grep -q "proxy_pass http://127.0.0.1:$APP_PORT/$APP_ID/;" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx must forward with the prefix to 127.0.0.1:$APP_PORT/$APP_ID/"; fail=1; }
  grep -q 'proxy_set_header Upgrade' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx is missing the WebSocket upgrade headers"; fail=1; }
  grep -q 'absolute_redirect off;' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx is missing absolute_redirect off (pitfall 13)"; fail=1; }

  log "checking webui.bz2 (contains .html / no macOS junk entries)..."
  tar tjf "$APP/webui.bz2" | grep -q '\.html$' || { warn "webui.bz2 has no html"; fail=1; }
  if tar tjf "$APP/webui.bz2" | grep -qE '(^|/)\._'; then
    warn "webui.bz2 contains AppleDouble ._ junk entries (macOS pollution)"
    fail=1
  fi

  log "checking webui.bz2 ownership (pitfall 46/S11: every entry must be root:root)..."
  python3 - "$APP/webui.bz2" <<'PYEOF' || fail=1
import sys, tarfile
bad = []
with tarfile.open(sys.argv[1]) as tf:
    for m in tf.getmembers():
        if m.uid != 0 or m.gid != 0:
            bad.append(m.name)
if bad:
    print(f"    entries with illegal ownership: {bad}", file=sys.stderr)
    sys.exit(1)
PYEOF

  log "checking BUILD-INFO (review V6: binaries must be source-built, no upstream prebuilts)..."
  local bi="$APP/bin/BUILD-INFO"
  if [ -f "$bi" ]; then
    grep -q '^built_from=source$' "$bi" \
      || { warn "BUILD-INFO lacks built_from=source"; fail=1; }
    grep -q "^source_tag=v$KAVITA_VERSION\$" "$bi" \
      || { warn "BUILD-INFO source_tag does not match KAVITA_VERSION"; fail=1; }
    grep -q '^built_by=github-actions$' "$bi" \
      || { warn "BUILD-INFO lacks built_by=github-actions"; fail=1; }
    log "  ok: $(grep '^source_tag=' "$bi")"
  else
    warn "missing bin/BUILD-INFO: the tarball is not a source build (automatic rejection under review item V6)"
    fail=1
  fi

  log "checking privacy-policy reachability (pitfall 45/C3: dual placement + exact nginx route)..."
  grep -q 'Privacy Policy' "$APP/privacy-policy.html" \
    || { warn "unexpected privacy-policy.html content"; fail=1; }
  grep -q "location = /$APP_ID/privacy-policy.html" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx is missing the exact privacy-policy route (pitfall 45/C3)"; fail=1; }

  log "zero-network scan (pitfall 15/S8: no online-install tokens in packaged scripts)..."
  local n_net
  n_net=$(grep -rniE 'pip(3)? install|pip download|--index-url|pypi\.(org|tuna)|urllib\.request|urlopen|npm install -g|curl .*(debian|ubuntu)\.org' \
      "$ASSETS_DIR" --include='*.sh' --include='*.py' --include='preinst' \
      --include='postinst' --include='prerm' --include='postrm' 2>/dev/null | wc -l | tr -d ' ' || true)
  [ "$n_net" = "0" ] || { warn "$n_net line(s) look like online-install tokens (S8 red line)"; fail=1; }

  log "checking ELF architecture (target: $ELF_ARCH, for GNU/Linux)..."
  local f
  for f in "$APP/bin/Kavita"; do
    if file "$f" | grep -q "ELF.*$ELF_ARCH"; then
      log "  ok: $(basename "$f")"
    else
      warn "wrong architecture: ${f#$STAGE_DIR/} -> $(file "$f")"
      fail=1
    fi
  done

  log "checking for macOS Mach-O contamination (must be 0)..."
  local n_macho
  n_macho=$(find "$APP" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_macho" -eq 0 ] || { warn "found $n_macho Mach-O file(s)!"; fail=1; }

  log "checking for residual macOS junk (.DS_Store / ._ sidecars; informational, the packer excludes them)..."
  local n_junk
  n_junk=$(find "$STAGE_DIR" \( -name '.DS_Store' -o -name '._*' \) 2>/dev/null | wc -l | tr -d ' ')
  [ "$n_junk" -eq 0 ] || warn "found $n_junk macOS junk file(s); makedeb.sh excludes them from the package"

  if [ "$fail" -eq 0 ]; then
    log "verification passed"
  else
    die "verification failed; review the warnings above"
  fi
}

# ============================================================
# Stage: deb - produce .deb + .sha256
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "not assembled yet; run ./build.sh stage first"

  # Guard against packaging a stale tree left over from the other architecture
  # (guide pitfall 28: "SKIP: using prebuilt" style mistakes produce a package
  # that is named for one arch but contains binaries of the other).
  local staged_bin="$STAGE_DIR/usr/local/$APP_ID/bin/Kavita"
  if [ -e "$staged_bin" ]; then
    file "$staged_bin" | grep -q "$ELF_ARCH" \
      || die "staged binary architecture does not match TARGET_ARCH=$TARGET_ARCH (want $ELF_ARCH, got: $(file "$staged_bin"))"
    log "  ok: staged binary architecture matches TARGET_ARCH=$TARGET_ARCH"
  fi
  mkdir -p "$OUT_DIR"
  # shellcheck source=makedeb.sh
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"

  # Companion sha256 (required for releases and store submissions; the file lists only the file name)
  local base
  base=$(basename "$DEB_FILE")
  if command -v sha256sum >/dev/null 2>&1; then
    ( cd "$OUT_DIR" && sha256sum "$base" > "$base.sha256" )
  else
    ( cd "$OUT_DIR" && shasum -a 256 "$base" > "$base.sha256" )
  fi
  log "done: $DEB_FILE (+ .sha256)"
  log "release tag must be v$VERSION_FULL"
  # Guard: the submission validator parses <app_id> from the asset file name and
  # only accepts "<app_id>_<platform>.deb" (platform = x86_64/aarch64, no version).
  # A non-compliant name made the validator look for the wrong app root and
  # report "missing required files: config.ini, <Id>.lang, <Id>.svg" (2026-09).
  case "$(basename "$DEB_FILE")" in
    "${APP_ID}_${TOS_PLATFORM}.deb") log "  ok: asset name matches <app_id>_<platform>.deb" ;;
    *) die "asset name must be ${APP_ID}_${TOS_PLATFORM}.deb (got $(basename "$DEB_FILE")); the platform derives <app_id> from it" ;;
  esac
}

stage_info() {
  cat <<EOF
Kavita version : $KAVITA_VERSION (full version $VERSION_FULL)
Target arch    : $TARGET_ARCH (TOS: $TOS_PLATFORM)
TOS app id     : $APP_ID (new tab /$APP_ID/, backend 127.0.0.1:$APP_PORT)
Artifact       : $DEB_FILE + .sha256 (release tag: v$VERSION_FULL)
EOF
}

stage_clean() {
  rm -rf "$STAGE_DIR" "$BUILD_DIR/webui"
  log "stage cleaned (download cache kept)"
}

stage_distclean() {
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  log "all build artifacts and the download cache were cleaned"
}

# ============================================================
# Entry point
# ============================================================
STAGE=${1:-all}
case "$STAGE" in
  fetch)      stage_fetch ;;
  stage)      stage_stage ;;
  deb)        stage_deb ;;
  all)        stage_fetch; stage_stage; stage_verify; stage_deb ;;
  clean)      stage_clean ;;
  distclean)  stage_distclean ;;
  verify)     stage_verify ;;
  info)       stage_info ;;
  *)          die "unknown stage: $STAGE (available: fetch stage deb verify clean distclean info)" ;;
esac
