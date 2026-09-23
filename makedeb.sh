#!/bin/sh
# ============================================================
# makedeb.sh - minimal deb packer with no dpkg dependency (works on macOS and Linux)
#
# How it works: a deb is an ar archive holding three members, in order:
#   1. debian-binary   "2.0\n"
#   2. control.tar.gz  (control/conffiles/postinst/prerm/postrm/md5sums)
#   3. data.tar.xz     (filesystem tree, root:root)
#
# Usage: makedeb.sh <pkgroot> <assets_dir> <out.deb> <version> <arch> <maintainer>
# ============================================================
set -eu

PKGROOT=$1
ASSETS=$2
OUTDEB=$3
VERSION=$4
ARCH=$5
MAINTAINER=$6

[ -d "$PKGROOT" ] || { echo "error: pkgroot does not exist: $PKGROOT" >&2; exit 1; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/makedeb.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# ---------- tool compatibility layer ----------
md5_of() { # md5_of <file> -> prints the 32-char hash
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | cut -d' ' -f1
  else
    md5 -q "$1"
  fi
}

# ---------- 1. generate DEBIAN/control ----------
INSTALLED_SIZE_KB=$(du -sk "$PKGROOT" | cut -f1)

# template variable substitution
CONTROL_SRC="$ASSETS/control.in"
if [ ! -f "$CONTROL_SRC" ]; then
  echo "error: missing $CONTROL_SRC" >&2
  exit 1
fi
sed -e "s|@VERSION@|$VERSION|g" \
    -e "s|@ARCH@|$ARCH|g" \
    -e "s|@SIZE@|$INSTALLED_SIZE_KB|g" \
    -e "s|@MAINTAINER@|$MAINTAINER|g" \
    "$CONTROL_SRC" > "$WORK/control"

DEBIAN_DIR="$PKGROOT/DEBIAN"
rm -rf "$DEBIAN_DIR"
mkdir -p "$DEBIAN_DIR"
cp "$WORK/control" "$DEBIAN_DIR/control"

# maintainer scripts (@VERSION@ injected; preinst/postinst/prerm/postrm)
for f in preinst postinst prerm postrm; do
  sed -e "s|@VERSION@|$VERSION|g" "$ASSETS/$f" > "$DEBIAN_DIR/$f"
  chmod 0755 "$DEBIAN_DIR/$f"
done

# ---------- 2. md5sums ----------
# Exclude macOS pollution (pitfall 8): .DS_Store and AppleDouble ._ sidecars must not enter the package or the manifest
# (the kavita tree is ~350 MB and takes minutes to compress; macOS may recreate them after the stage cleanup,
#  so the packer has to exclude them as a last line of defence)
( cd "$PKGROOT"
  find . -type f ! -path './DEBIAN/*' \
         ! -name '.DS_Store' ! -name '._*' | LC_ALL=C sort | while IFS= read -r f; do
    f=${f#./}
    printf '%s  %s\n' "$(md5_of "$f")" "$f"
  done
) > "$DEBIAN_DIR/md5sums"

# ---------- 3. build data.tar.xz and control.tar.gz ----------
# Note: Python tarfile(GNU_FORMAT) is mandatory here, not bsdtar --
#   even with --format gnutar, macOS bsdtar inserts PAX extended headers
#   (type 'x') for long paths or unusual metadata, and dpkg only accepts plain ustar/gnu headers:
#   "corrupted filesystem tarfile ... unsupported PAX tar header type 'x'"
#   Python GNU_FORMAT guarantees plain GNU headers with fully controlled uid/gid/uname/gname/mtime
#   (root:root plus normalised mtime, which also helps reproducible builds).
python3 - "$PKGROOT" "$WORK" <<'PYEOF'
import os, sys, tarfile

pkgroot, work = sys.argv[1], sys.argv[2]

def build(out_path, src_dir, exclude_debian=False):
    mode = 'w:xz' if out_path.endswith('.xz') else 'w:gz'
    with tarfile.open(out_path, mode, format=tarfile.GNU_FORMAT) as tf:
        entries = []
        for root, dirs, files in os.walk(src_dir):
            dirs.sort()
            for name in sorted(dirs) + sorted(files):
                # Exclude macOS pollution (pitfall 8): .DS_Store / AppleDouble ._ sidecars
                if name == '.DS_Store' or name.startswith('._'):
                    continue
                entries.append(os.path.join(root, name))
        for full in entries:
            rel = './' + os.path.relpath(full, src_dir)
            if exclude_debian and rel.startswith('./DEBIAN'):
                continue
            ti = tf.gettarinfo(full, arcname=rel)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = 'root'
            ti.mtime = 0
            if ti.isfile():
                with open(full, 'rb') as f:
                    tf.addfile(ti, f)
            else:
                tf.addfile(ti)

build(os.path.join(work, 'data.tar.xz'), pkgroot, exclude_debian=True)
build(os.path.join(work, 'control.tar.gz'), os.path.join(pkgroot, 'DEBIAN'))
print('tar archives written (GNU_FORMAT, root:root, mtime=0)')
PYEOF

# ---------- 4. assemble the ar archive ----------
printf '2.0\n' > "$WORK/debian-binary"
# Member order must be debian-binary, control.tar.*, data.tar.*
# -S: do not write the ar symbol table (dpkg requirement)
rm -f "$OUTDEB"
ar rcS "$OUTDEB" "$WORK/debian-binary" "$WORK/control.tar.gz" "$WORK/data.tar.xz"

# ---------- 5. verification ----------
if command -v dpkg-deb >/dev/null 2>&1; then
  echo "--- dpkg-deb verification ---"
  dpkg-deb --info "$OUTDEB" | head -20
  dpkg-deb --contents "$OUTDEB" | head -5
  echo "..."
else
  echo "(no dpkg-deb on this host; skipped. Inspect the deb on the target with dpkg -c)"
fi

echo "packaged: $OUTDEB ($(du -h "$OUTDEB" | cut -f1), Installed-Size: ${INSTALLED_SIZE_KB}KB)"
