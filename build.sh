#!/usr/bin/env bash
# ============================================================
# build.sh - 在 macOS / Linux 上把 Kavita 打包成 TOS 7 应用中心
# 规范的 deb 包（WebUI External Open / 新标签页模式）
#
# 规范依据: https://help.terra-master.com/developer/development-docs/
#   - Deb Development Specification（目录结构/config.ini/nginx/systemd/生命周期）
#   - Package Specification（版本号三处一致、资产命名）
#
# 模式说明（navidrome 同款"保留前缀"方案）:
#   Kavita 官方支持子路径部署（appsettings.json 的 BaseUrl +
#   Startup.UsePathBase + SPA <base href>），nginx 不剥离 /kavita/
#   前缀而是原样转发，应用自身在子路径下原生工作，阅读器/API/
#   OPDS/SignalR 全部自洽。
#   Kavita 无 CLI 配置参数也不支持环境变量覆盖（上游清空了 env 配置源），
#   安全兜底落在 config/appsettings.json 模板（Port/IpAddresses/BaseUrl
#   三值由 verify 阶段断言），经 bin/config -> /var/lib/kavita 符号链接
#   生效；首装由 postinst 投放 appsettings-init.json，应用首启自行
#   重命名并生成 JWT TokenKey。
#
# 产物（out/）:
#   kavita_<版本>_<arch>.deb       完整版本名 deb（本地安装/测试用）
#   kavita_<platform>.deb          Release 资产名 deb（上架上传用，版本由 Release tag 表达）
#   kavita_<platform>.deb.sha256   上架要求的校验文件
#
# 阶段: fetch → stage → verify → deb
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# 允许 TARGET_ARCH=arm64 ./build.sh 覆盖 config.env 的默认值
# （先快照进程环境里的值，source 后再回填）
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

# 完整版本 = 上游版本-打包迭代号（如 0.9.1.4-1）
# 三处必须一致：config.ini / DEBIAN/control / .lang
VERSION_FULL="${KAVITA_VERSION}-${PKG_RELEASE}"

# ---------------- 目标平台（TOS / NAS 侧） ----------------
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
    echo "错误: 未知 TARGET_ARCH=$TARGET_ARCH（支持 amd64 / arm64）" >&2
    exit 1
    ;;
esac

TAG="v$KAVITA_VERSION"
# 审核 V6（一票否决）：二进制改为公开 CI 从上游源码 tag 自建
# （Moechz/kavita build-upstream.yml，步骤与上游 release-workflow.yml 逐字
# 对齐），不再从上游 Release 下载预编译 tarball；tarball 自带 BUILD-INFO
# 溯源文件，verify 阶段断言 built_from=source。
RELEASE_BASE="https://github.com/$SELF_BUILD_REPO/releases/download/build-$TAG"
TGZ="kavita-linux-${K_ARCH}.tar.gz"
# Kavita 上游不发布 checksums 文件 → 用 config.env 锚点 + 本地 lock 双保险
LOCK_FILE="$DL_DIR/sha256.lock"
DEB_FILE="$OUT_DIR/${APP_ID}_${VERSION_FULL}_${TARGET_ARCH}.deb"
STORE_DEB="$OUT_DIR/${APP_ID}_${TOS_PLATFORM}.deb"       # Release 资产命名（无版本）

MAINTAINER_FULL="$MAINTAINER_NAME <$MAINTAINER_EMAIL>"

log()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m警告:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m错误:\033[0m %s\n' "$*" >&2; exit 1; }

fetch() { # fetch <url> <dest-file>（多次重试 + 断点续传）
  local url=$1 dest=$2 attempt=0
  if [ -s "$dest" ]; then
    log "已缓存: $(basename "$dest")"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  log "下载: $(basename "$dest")"
  while [ $attempt -lt 8 ]; do
    attempt=$((attempt + 1))
    if curl -fL --retry 5 --retry-delay 3 --retry-all-errors \
         --connect-timeout 30 -C - -o "$dest.part" "$url"; then
      mv "$dest.part" "$dest"
      return 0
    fi
    rm -f "$dest.part"  # 部分服务器不支持续传时从头再来
    warn "下载失败(第 $attempt 次): $(basename "$dest")，10 秒后重试..."
    sleep 10
  done
  die "下载失败: $url"
}

sha256_of() { # sha256_of <file> -> 64 位哈希（macOS/Linux 兼容）
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  else
    shasum -a 256 "$1" | cut -d' ' -f1
  fi
}

# sha256 锚定：优先 config.env 的手工锚点，其次本地 lock（防缓存被换包）
verify_sha256() { # verify_sha256 <file-全路径> <pinned-value>；lock 键用 basename
  local f=$1 base pinned=${2:-} got locked
  base=$(basename "$f")
  got=$(sha256_of "$f")
  if [ -n "$pinned" ]; then
    [ "$got" = "$pinned" ] || die "sha256 与 config.env 锚点不符: $base（want=$pinned got=$got）"
    log "  ok: $base（config.env 锚点校验通过）"
    return 0
  fi
  locked=$(grep -a "^$base " "$LOCK_FILE" 2>/dev/null | awk '{print $2}' || true)
  if [ -n "$locked" ]; then
    [ "$got" = "$locked" ] || die "sha256 与本地 lock 不符: $base（lock=$locked got=$got，若确认无风险可删 lock 后重跑）"
    log "  ok: $base（lock 校验通过）"
  else
    mkdir -p "$DL_DIR"
    echo "$base $got" >> "$LOCK_FILE"
    warn "已记录 sha256 到 $LOCK_FILE（建议固化进 config.env 的 KAVITA_*_SHA256）: $got"
  fi
}

normalize_text() { # 规范要求：文本文件 LF 行尾 + UTF-8 无 BOM（构建时统一清洗）
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
# 阶段: fetch
# ============================================================
stage_fetch() {
  mkdir -p "$DL_DIR"

  # 1. Kavita 运行时（公开 CI 自上游源码构建；.NET self-contained，含 wwwroot/I18N）
  fetch "$RELEASE_BASE/$TGZ" "$DL_DIR/$TGZ"

  # 1b. SHA256SUMS 双层互验（坑 48 陷阱 3）：Release 清单 × config.env 锚点
  #     两层独立来源互验，防资产被替换/下载损坏；若本地缓存是旧版预编译
  #     tarball 会在此报错，删 build/downloads/kavita-linux-*.tar.gz 后重跑
  fetch "$RELEASE_BASE/SHA256SUMS" "$DL_DIR/SHA256SUMS-$KAVITA_VERSION"
  local sums_line
  sums_line=$(grep -a " $TGZ\$" "$DL_DIR/SHA256SUMS-$KAVITA_VERSION" | head -1 | awk '{print $1}')
  [ -n "$sums_line" ] || die "SHA256SUMS 中找不到 $TGZ（Release 资产不完整？）"
  [ "$(sha256_of "$DL_DIR/$TGZ")" = "$sums_line" ] \
    || die "$TGZ 与 Release SHA256SUMS 不符（若为旧缓存请删 build/downloads/kavita-linux-*.tar.gz 后重跑）"
  log "  ok: $TGZ（Release SHA256SUMS 双层互验通过）"

  # 2. 上游 LICENSE 兜底预取（仅当 tarball 不随包 LICENSE 时才会用到；
  #    成员名在 stage 阶段重新探测，保证单跑 stage 世能工作）
  if ! tar tzf "$DL_DIR/$TGZ" 2>/dev/null | grep -qiE '(^|/)LICENSE$'; then
    fetch "https://raw.githubusercontent.com/Kareadita/Kavita/$TAG/LICENSE" "$DL_DIR/LICENSE"
  fi

  # 3. sha256 校验（锚点/lock 逻辑见 verify_sha256）
  log "校验 sha256..."
  verify_sha256 "$DL_DIR/$TGZ" "$PINNED_SHA"
}

# ============================================================
# 阶段: stage —— 组装 deb 文件系统树（官方规范布局）
# ============================================================
stage_stage() {
  [ -s "$DL_DIR/$TGZ" ] || die "缺少 $TGZ，请先运行: ./build.sh fetch"

  local APP="$STAGE_DIR/usr/local/$APP_ID"
  log "组装文件系统树: $STAGE_DIR（/usr/local/$APP_ID 规范布局）"
  rm -rf "$STAGE_DIR"
  mkdir -p "$APP/bin"
  mkdir -p "$APP/config-template"
  mkdir -p "$APP/images/icons"
  mkdir -p "$APP/nginx"
  mkdir -p "$APP/init.d"
  mkdir -p "$STAGE_DIR/usr/share/doc/$APP_ID"

  # 运行时树：tarball 里除 config/ 外全部进 bin/
  # （Kavita 以 CWD 解析一切：wwwroot/I18N/Assets/EmailTemplates 必须与
  #  进程 CWD 同级，故整个运行时树放 bin/ 下，WorkingDirectory 指向它）
  # tarball 可能带顶层 Kavita/ 目录也可能平铺，这里自动识别
  log "  + bin/（上游 $KAVITA_VERSION 运行时树，剔除上游 config/）"
  local top prefix_args=()
  top=$(tar tzf "$DL_DIR/$TGZ" | head -1 | cut -d/ -f1)
  if tar tzf "$DL_DIR/$TGZ" | grep -qv "^$top/\|^$top$"; then
    # 平铺结构（顶层即文件/目录混合）
    tar xzf "$DL_DIR/$TGZ" -C "$APP/bin" \
      --exclude='config' --exclude='config/*'
  else
    # 单一顶层目录
    tar xzf "$DL_DIR/$TGZ" -C "$APP/bin" --strip-components=1 \
      --exclude="$top/config" --exclude="$top/config/*"
  fi
  rm -rf "$APP/bin/config"
  [ -f "$APP/bin/Kavita" ] || die "tarball 内未找到 Kavita 可执行文件（结构变化？请检查 $DL_DIR/$TGZ）"
  # 上游 tarball 的 apphost 存 0644（实测），必须补执行位；
  # createdump 同样补上（崩溃时生成 core dump 用）；其余文件保留上游原权限
  chmod 0755 "$APP/bin/Kavita"
  [ -x "$APP/bin/createdump" ] && chmod 0755 "$APP/bin/createdump" || true
  [ -x "$APP/bin/Kavita" ] || die "Kavita 赋权后仍不可执行（异常）"

  # SPA base href 预写为子路径（前缀保留方案的配套动作）：
  # 上游启动时会自行把 BaseUrl 写回 wwwroot/index.html 的 <base href>，
  # 构建期先写同值，保证应用在只读沙箱下改写失败时行为仍正确
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
        raise SystemExit('wwwroot/index.html 中既无 <base> 也无 <head>，无法注入 base href')
open(p, 'w', encoding='utf-8').write(new)
PYEOF

  # config 符号链接：Kavita 状态目录 = $(CWD)/config/*，指向数据卷
  log "  + bin/config -> /var/lib/$APP_ID（状态目录落数据卷的符号链接）"
  ln -s "/var/lib/$APP_ID" "$APP/bin/config"

  # config.ini（严格 JSON；@@...@@ 占位符渲染）
  log "  + config.ini（External Open: open_path=true, path=/$APP_ID/）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@PUBLISHER@@|$PUBLISHER|g" \
      -e "s|@@PLATFORM@@|$TOS_PLATFORM|g" \
      "$ASSETS_DIR/config.ini.in" > "$APP/config.ini"

  # 多语言文件（文件名必须等于 app id；23 语超集，覆盖真机 14 语与官方 14 语两个口径）
  log "  + $APP_ID.lang（23 语言）"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      "$ASSETS_DIR/$APP_ID.lang" > "$APP/$APP_ID.lang"

  # 图标（官方 logo，viewBox 0 0 64 64，品牌圆形底；文件名必须等于 app id）
  log "  + images/icons/$APP_ID.svg"
  cp "$ASSETS_DIR/images/icons/$APP_ID.svg" "$APP/images/icons/$APP_ID.svg"

  # nginx 路由：app 目录内 nginx/ 满足 TOS 规范；同时以 dpkg 实体文件放
  # /etc/nginx/conf.d（metube/navidrome 双项目验证的双落盘模式）
  log "  + nginx/ + /etc/nginx/conf.d/（127.0.0.1:$APP_PORT 回环反代，保留前缀）"
  mkdir -p "$STAGE_DIR/etc/nginx/conf.d"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$APP/nginx/$APP_ID.conf"
  cp "$ASSETS_DIR/nginx/$APP_ID.conf" "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf"

  # systemd 服务：init.d/ 满足 TOS 规范；同时以 dpkg 实体文件放
  # /etc/systemd/system（双落盘模式，systemd 直接加载，不依赖 postinst 拷贝）
  log "  + init.d/ + /etc/systemd/system/"
  mkdir -p "$STAGE_DIR/etc/systemd/system"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$APP/init.d/$APP_ID.service"
  cp "$ASSETS_DIR/init.d/$APP_ID.service" "$STAGE_DIR/etc/systemd/system/$APP_ID.service"

  # webui.bz2（WebUI 类应用必填；解压须含可打开的 .html。Kavita 前端内嵌于
  # 运行时树、经 nginx 路由提供，此处为规范要求的占位前端）
  log "  + webui.bz2（占位前端，跳转 /$APP_ID/）"
  local WEBUI_DIR="$BUILD_DIR/webui"
  rm -rf "$WEBUI_DIR"
  mkdir -p "$WEBUI_DIR"
  sed -e "s|@@VERSION@@|$VERSION_FULL|g" \
      -e "s|@@APP_PORT@@|$APP_PORT|g" \
      "$ASSETS_DIR/webui/index.html" > "$WEBUI_DIR/index.html"
  # 坑 8（macOS 污染）：bsdtar 会把扩展属性存成 AppleDouble ._ 条目打进归档。
  # 双保险：COPYFILE_DISABLE=1 禁用 + 打包前删除 ._ 文件
  find "$WEBUI_DIR" -name '._*' -delete 2>/dev/null || true
  # 坑 46（S11 警告实锤）：嵌套归档条目属主必须是 root:root，macOS bsdtar
  # 无 --owner 参数，改用 python tarfile 重打（uid/gid=0、uname/gname=root、mtime=0）
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

  # Kavita 配置模板（postinst 首装投放 appsettings-init.json 的源；
  # Kavita 首启重命名为 appsettings.json 并自动生成 JWT TokenKey）
  log "  + config-template/appsettings-init.json（Port=$APP_PORT / 回环 / BaseUrl=/$APP_ID/）"
  sed -e "s|@@APP_PORT@@|$APP_PORT|g" \
      "$ASSETS_DIR/appsettings-init.json" > "$APP/config-template/appsettings-init.json"

  # 配置模板（以 .example 随包分发，postinst 首装复制为正式 env；升级不覆盖）
  log "  + $APP_ID.env.example 配置模板"
  cp "$ASSETS_DIR/$APP_ID.env" "$APP/$APP_ID.env.example"

  # 隐私政策（审核 C3 必备资产）：双落盘包内 + nginx 精确路由直出（坑 45）
  log "  + privacy-policy.html（双语，nginx 精确路由 /$APP_ID/privacy-policy.html）"
  cp "$ASSETS_DIR/privacy-policy.html" "$APP/privacy-policy.html"

  # 二进制溯源链说明（审核 V6 审计者材料，坑 31/32/43）
  log "  + PROVENANCE.md（源码构建审计链）"
  cp "$ASSETS_DIR/PROVENANCE.md" "$STAGE_DIR/usr/share/doc/$APP_ID/PROVENANCE.md"

  # 文档（tar 列表精确匹配 LICENSE 成员名，不猜路径形态；缺失时用 fetch 预取的副本）
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
    echo "  * 基于 Kavita 上游 $KAVITA_VERSION 打包"
    echo "  * 运行时由公开 CI 从上游源码构建（sha256 双层锚定），.NET self-contained 零运行时依赖"
    echo "  * WebUI External Open：新标签页经 /$APP_ID/ 路由访问，后端仅监听回环"
    echo "  * 子路径经 BaseUrl=/$APP_ID/ 原生支持（SPA base href 构建期预写）"
    echo "  * 状态目录经 bin/config 符号链接落在 /var/lib/$APP_ID"
    echo ""
    echo " -- $MAINTAINER_FULL  $(date -R 2>/dev/null || date '+%a, %d %b %Y %H:%M:%S %z')"
  } > "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian"

  # 规范清洗：LF 行尾 + 去 BOM（所有文本资产；不动二进制运行时树）
  log "  清洗行尾（LF）与 BOM"
  normalize_text \
    "$APP/config.ini" "$APP/$APP_ID.lang" \
    "$APP/nginx/$APP_ID.conf" \
    "$STAGE_DIR/etc/nginx/conf.d/$APP_ID.conf" \
    "$APP/init.d/"*.service \
    "$STAGE_DIR/etc/systemd/system/"*.service \
    "$APP/config-template/appsettings-init.json" \
    "$APP/privacy-policy.html" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/PROVENANCE.md" \
    "$APP/"*.example \
    "$STAGE_DIR/usr/share/doc/$APP_ID/changelog.Debian" \
    "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"

  # 清理 macOS 扩展属性，避免污染 tar（AppleDouble / quarantine）
  if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$STAGE_DIR" >/dev/null 2>&1 || true
  fi
  find "$STAGE_DIR" -name '._*' -delete 2>/dev/null || true
  find "$STAGE_DIR" -name '.DS_Store' -delete 2>/dev/null || true

  log "组装完成"
}

# ============================================================
# 阶段: verify —— 目标架构与规范关键项校验
# ============================================================
stage_verify() {
  local APP="$STAGE_DIR/usr/local/$APP_ID"
  [ -d "$APP" ] || die "尚未组装，请先运行: ./build.sh stage"
  local fail=0

  log "校验规范关键路径..."
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
           "$APP/bin/BUILD-INFO" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/PROVENANCE.md" \
           "$STAGE_DIR/usr/share/doc/$APP_ID/copyright"; do
    [ -e "$p" ] || { warn "缺失: ${p#$STAGE_DIR/}"; fail=1; }
  done

  log "校验 config.ini（JSON 合法性 / 互斥字段 / 版本一致性）..."
  python3 - "$APP/config.ini" "$VERSION_FULL" "$TOS_PLATFORM" "$APP_ID" "$APP_USER" <<'PYEOF' || fail=1
import json, sys
cfg_path, want_ver, want_plat, app_id, app_user = sys.argv[1:6]
cfg = json.load(open(cfg_path))
errs = []
if cfg.get("id") != app_id: errs.append(f"id != {app_id}")
if cfg.get("version") != want_ver: errs.append(f"version != {want_ver}")
if cfg.get("system_id") != app_id: errs.append("system_id 不一致")
if cfg.get("package") != app_id: errs.append("package 不一致")
if cfg.get("platform") != want_plat: errs.append(f"platform != {want_plat}")
# WebUI External Open: open_path=true 且不得出现 type；path=/<id>/
if cfg.get("open_path") is not True: errs.append("open_path 必须为 true")
if "type" in cfg: errs.append("不得包含 type 字段（与 open_path 互斥）")
if cfg.get("path") != f"/{app_id}/": errs.append(f"path 必须为 /{app_id}/")
if cfg.get("user") != app_user: errs.append(f"user 应为 {app_user}")
if cfg.get("recommend") is not False: errs.append("recommend 提交时必须为 false")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 .lang（23 语超集齐全）..."
  local lang_missing
  lang_missing=$(python3 - "$APP/$APP_ID.lang" <<'PYEOF'
import sys
required = ["zh-cn","zh-hk","en-us","fr-fr","de-de","it-it","es-es",
            "hu-hu","ja-jp","ko-kr","pl-pl","ru-ru","tr-tr","pt-pt",
            "ar-sa","cs-cz","he-il","id-id","nb-no","nl-nl","sv-se",
            "th-th","vi-vn"]
text = open(sys.argv[1], encoding="utf-8").read()
missing = [t for t in required if f"[{t}]" not in text]
print(",".join(missing))
PYEOF
)
  [ -z "$lang_missing" ] || { warn "lang 缺少语言节: $lang_missing"; fail=1; }

  log "校验 appsettings 模板（回环监听/端口/子路径安全兜底）..."
  python3 - "$APP/config-template/appsettings-init.json" "$APP_PORT" "$APP_ID" <<'PYEOF' || fail=1
import json, sys
cfg = json.load(open(sys.argv[1]))
port, app_id = sys.argv[2], sys.argv[3]
errs = []
if cfg.get("IpAddresses") != "127.0.0.1": errs.append("IpAddresses 必须为 127.0.0.1")
if cfg.get("Port") != int(port): errs.append(f"Port 必须为 {port}")
if cfg.get("BaseUrl") != f"/{app_id}/": errs.append(f"BaseUrl 必须为 /{app_id}/")
if not str(cfg.get("TokenKey","")).startswith("super secret unguessable key"):
    errs.append("TokenKey 必须为上游占位值（由 Kavita 首启自动生成）")
for e in errs:
    print(f"    校验失败: {e}", file=sys.stderr)
sys.exit(1 if errs else 0)
PYEOF

  log "校验 SPA base href（子路径下前端资源寻址依赖）..."
  grep -q "<base href=\"/$APP_ID/\">" "$APP/bin/wwwroot/index.html" \
    || { warn "wwwroot/index.html 缺少 <base href=\"/$APP_ID/\">"; fail=1; }

  log "校验 config 符号链接（状态目录必须落数据卷）..."
  [ -L "$APP/bin/config" ] || { warn "bin/config 必须是符号链接"; fail=1; }
  [ "$(readlink "$APP/bin/config")" = "/var/lib/$APP_ID" ] \
    || { warn "bin/config 必须指向 /var/lib/$APP_ID（当前: $(readlink "$APP/bin/config" 2>/dev/null || echo none)）"; fail=1; }
  [ -e "$APP/bin/config" ] && warn "注意: 数据卷目录在本机不存在属正常（目标机上创建）"

  log "校验 systemd 服务（禁 Restart/必配 StartLimit/禁 ExecStart 变量展开）..."
  local svc
  for svc in "$APP/init.d/"*.service \
             "$STAGE_DIR/etc/systemd/system/"*.service; do
    grep -q '^\[Unit\]' "$svc" || { warn "非 systemd unit: $svc"; fail=1; }
    grep -Eq '^Restart' "$svc" && { warn "规范禁止配置 Restart: $svc"; fail=1; }
    grep -Eq '^ExecStart=.*\$' "$svc" && { warn "ExecStart 禁用变量展开（曾致全环境 502）: $svc"; fail=1; }
    grep -q '^StartLimitBurst=' "$svc" || { warn "缺少 StartLimitBurst: $svc"; fail=1; }
    grep -q '^StartLimitIntervalSec=' "$svc" || { warn "缺少 StartLimitIntervalSec: $svc"; fail=1; }
    grep -q "^User=$APP_USER" "$svc" || { warn "必须 User=$APP_USER: $svc"; fail=1; }
    grep -q "^WorkingDirectory=/usr/local/$APP_ID/bin$" "$svc" \
      || { warn "必须 WorkingDirectory=/usr/local/$APP_ID/bin: $svc"; fail=1; }
    grep -q '^ReadWritePaths=/var/lib/' "$svc" \
      || { warn "必须 ReadWritePaths=/var/lib/$APP_ID: $svc"; fail=1; }
  done
  # init.d/ 只允许一个与 system_id 同名的主服务单元（多单元会卡死应用中心安装）
  local n_units
  n_units=$(find "$APP/init.d" -name '*.service' | wc -l | tr -d ' ')
  [ "$n_units" = "1" ] || { warn "init.d/ 必须恰好 1 个 service（当前 $n_units 个，坑 11）"; fail=1; }

  log "校验 nginx（前缀保留转发 + WebSocket + 回环）..."
  grep -q "proxy_pass http://127.0.0.1:$APP_PORT/$APP_ID/;" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 必须保留前缀转发到 127.0.0.1:$APP_PORT/$APP_ID/"; fail=1; }
  grep -q 'proxy_set_header Upgrade' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺 WebSocket 升级头"; fail=1; }
  grep -q 'absolute_redirect off;' "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺 absolute_redirect off（坑 13）"; fail=1; }

  log "校验 webui.bz2（解压含 .html / 无 macOS 垃圾条目）..."
  tar tjf "$APP/webui.bz2" | grep -q '\.html$' || { warn "webui.bz2 缺少 html"; fail=1; }
  if tar tjf "$APP/webui.bz2" | grep -qE '(^|/)\._'; then
    warn "webui.bz2 含 AppleDouble ._ 垃圾条目（macOS 污染）"
    fail=1
  fi

  log "校验 webui.bz2 属主（坑 46/S11：全部条目必须 root:root）..."
  python3 - "$APP/webui.bz2" <<'PYEOF' || fail=1
import sys, tarfile
bad = []
with tarfile.open(sys.argv[1]) as tf:
    for m in tf.getmembers():
        if m.uid != 0 or m.gid != 0:
            bad.append(m.name)
if bad:
    print(f"    非法属主条目: {bad}", file=sys.stderr)
    sys.exit(1)
PYEOF

  log "校验 BUILD-INFO（审核 V6：二进制必须源码自建，禁预编译上游产物）..."
  local bi="$APP/bin/BUILD-INFO"
  if [ -f "$bi" ]; then
    grep -q '^built_from=source$' "$bi" \
      || { warn "BUILD-INFO 缺 built_from=source"; fail=1; }
    grep -q "^source_tag=v$KAVITA_VERSION\$" "$bi" \
      || { warn "BUILD-INFO source_tag 与 KAVITA_VERSION 不符"; fail=1; }
    grep -q '^built_by=github-actions$' "$bi" \
      || { warn "BUILD-INFO 缺 built_by=github-actions"; fail=1; }
    log "  ok: $(grep '^source_tag=' "$bi")"
  else
    warn "缺 bin/BUILD-INFO：tarball 非源码自建产物（审核 V6 一票否决项）"
    fail=1
  fi

  log "校验隐私政策可达（坑 45/C3：包内双落盘 + nginx 精确路由）..."
  grep -q 'Privacy Policy' "$APP/privacy-policy.html" \
    || { warn "privacy-policy.html 内容异常"; fail=1; }
  grep -q "location = /$APP_ID/privacy-policy.html" "$APP/nginx/$APP_ID.conf" \
    || { warn "nginx 缺隐私政策精确路由（坑 45/C3）"; fail=1; }

  log "零网络扫描（坑 15/S8：包内脚本不得出现在线安装令牌）..."
  local n_net
  n_net=$(grep -rniE 'pip(3)? install|pip download|--index-url|pypi\.(org|tuna)|urllib\.request|urlopen|npm install -g|curl .*(debian|ubuntu)\.org' \
      "$ASSETS_DIR" --include='*.sh' --include='*.py' --include='preinst' \
      --include='postinst' --include='prerm' --include='postrm' 2>/dev/null | wc -l | tr -d ' ')
  [ "$n_net" = "0" ] || { warn "发现 $n_net 行疑似在线安装令牌（S8 红线）"; fail=1; }

  log "校验 ELF 架构（目标: $ELF_ARCH, for GNU/Linux）..."
  local f
  for f in "$APP/bin/Kavita"; do
    if file "$f" | grep -q "ELF.*$ELF_ARCH"; then
      log "  ok: $(basename "$f")"
    else
      warn "错误架构: ${f#$STAGE_DIR/} -> $(file "$f")"
      fail=1
    fi
  done

  log "检查 macOS Mach-O 混入（应为 0）..."
  local n_macho
  n_macho=$(find "$APP" -type f -exec file {} + 2>/dev/null | grep -c "Mach-O" || true)
  [ "$n_macho" -eq 0 ] || { warn "发现 $n_macho 个 Mach-O 文件！"; fail=1; }

  log "检查 macOS 污染物残留（.DS_Store / ._ 边车，仅提示；打包器兑底排除）..."
  local n_junk
  n_junk=$(find "$STAGE_DIR" \( -name '.DS_Store' -o -name '._*' \) 2>/dev/null | wc -l | tr -d ' ')
  [ "$n_junk" -eq 0 ] || warn "发现 $n_junk 个 macOS 污染物（makedeb.sh 已兑底排除，不入包）"

  if [ "$fail" -eq 0 ]; then
    log "校验通过 ✅"
  else
    die "校验失败，请检查上方警告"
  fi
}

# ============================================================
# 阶段: deb —— 生成 .deb + 上架资产
# ============================================================
stage_deb() {
  [ -d "$STAGE_DIR/usr/local/$APP_ID" ] || die "尚未组装，请先运行: ./build.sh stage"
  mkdir -p "$OUT_DIR"
  # shellcheck source=makedeb.sh
  "$SCRIPT_DIR/makedeb.sh" "$STAGE_DIR" "$ASSETS_DIR" "$DEB_FILE" \
    "$VERSION_FULL" "$TARGET_ARCH" "$MAINTAINER_FULL"

  # Release 资产命名（版本由 Release tag 表达）+ 上架要求的 sha256
  cp "$DEB_FILE" "$STORE_DEB"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$STORE_DEB" | awk '{print $1"  "$2}' > "$STORE_DEB.sha256"
  else
    shasum -a 256 "$STORE_DEB" | awk '{print $1"  "$2}' > "$STORE_DEB.sha256"
  fi
  log "完成: $DEB_FILE"
  log "上架资产: $STORE_DEB (+ .sha256；Release tag 须为 v$VERSION_FULL)"
}

stage_info() {
  cat <<EOF
Kavita 版本    : $KAVITA_VERSION (完整版本 $VERSION_FULL)
目标架构       : $TARGET_ARCH (TOS:$TOS_PLATFORM)
TOS app id     : $APP_ID（新标签页 /$APP_ID/，后端 127.0.0.1:$APP_PORT）
产物           : $DEB_FILE
上架资产       : $STORE_DEB + .sha256（Release tag: v$VERSION_FULL）
EOF
}

stage_clean() {
  rm -rf "$STAGE_DIR" "$BUILD_DIR/webui"
  log "已清理 stage（保留下载缓存）"
}

stage_distclean() {
  rm -rf "$BUILD_DIR" "$OUT_DIR"
  log "已清理全部构建产物与下载缓存"
}

# ============================================================
# 入口
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
  *)          die "未知阶段: $STAGE（可用: fetch stage deb verify clean distclean info）" ;;
esac
