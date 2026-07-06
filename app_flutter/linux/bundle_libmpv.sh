#!/usr/bin/env bash
# Bundle libmpv + non-base dependencies into the Flutter Linux release bundle,
# so the app plays audio without any system-installed mpv. Rootless: uses
# `dnf download` + rpm2cpio. Re-run after every `flutter build linux`.
#
# Usage: linux/bundle_libmpv.sh [bundle-dir] (default: release bundle)
set -euo pipefail

BUNDLE=${1:-"$(dirname "$0")/../build/linux/x64/release/bundle"}
LIB="$BUNDLE/lib"
PATCHELF=${PATCHELF:-patchelf}
[ -d "$LIB" ] || { echo "no bundle at $BUNDLE — run flutter build linux first" >&2; exit 1; }
# Fail up front: the per-file patchelf loop below tolerates errors, so a
# missing binary would otherwise pass silently and leave rpaths unset.
command -v "$PATCHELF" >/dev/null || { echo "patchelf not found — dnf install patchelf or set PATCHELF=" >&2; exit 1; }

work=$(mktemp -d); trap 'chmod -R u+w "$work" 2>/dev/null; rm -rf "$work"' EXIT
echo "downloading mpv-libs + dependency RPMs..."
# --resolve: mpv-libs + deps missing on this host (installed ones load from
# the system). ponytail: not a portable bundle — Flatpak is the answer for
# shipping to arbitrary machines; this makes THIS machine self-sufficient.
# libXScrnSaver/libXpresent: tiny X client libs mpv links that desktop
# stacks often lack; safe to ship (never loaded by the Flutter/GTK shell).
dnf download --resolve --arch x86_64 --arch noarch --destdir "$work" \
  mpv-libs libXScrnSaver libXpresent 2>&1 | tail -2
# No pipe: rpm2cpio dies of SIGPIPE (141) under pipefail when cpio finishes
# reading before rpm2cpio finishes writing trailing padding.
(cd "$work" && for r in *.rpm; do
  rpm2cpio "$r" > payload.cpio
  cpio -idmu --quiet < payload.cpio
done && rm -f payload.cpio)
shopt -s nullglob

# Never ship base-system or desktop-stack libs: glibc family must come from
# the host, and glib/gtk/X/wayland are already loaded by the Flutter shell —
# a second copy in-process causes symbol clashes.
SKIP='^(ld-linux|libc\.|libm\.|libdl|libpthread|librt\.|libresolv|libgcc_s|libstdc\+\+|libglib|libgobject|libgio|libgmodule|libgtk|libgdk|libX|libxcb|libwayland|libxkb|libsystemd|libselinux|libmount|libblkid|libpcre|libffi\.|libz\.|libzstd|liblzma|libbz2)'

copied=0
for f in "$work"/usr/lib64/*.so* "$work"/usr/lib/*.so*; do
  base=$(basename "$f")
  case "$base" in
    libXss*|libXpresent*) ;;                        # always ship these two
    *) [[ $base =~ $SKIP ]] && continue ;;
  esac
  cp -a "$f" "$LIB/"
  copied=$((copied + 1))
done
echo "copied $copied libs into $LIB"

# $ORIGIN rpath so bundled libs resolve each other before the system.
find "$LIB" -name '*.so*' -type f | while read -r so; do
  "$PATCHELF" --set-rpath '$ORIGIN' "$so" 2>/dev/null || true
done

ln -sf libmpv.so.2 "$LIB/libmpv.so"

missing=$(LD_LIBRARY_PATH= ldd "$LIB/libmpv.so" | awk '/not found/{print $1}')
if [ -n "$missing" ]; then
  echo "UNRESOLVED (present on most desktops, or extend the download list):" >&2
  echo "$missing" >&2
  exit 1
fi
echo "libmpv bundled and fully resolved."
