#!/usr/bin/env bash
# Build aria-linux-x86_64.AppImage from an already-built Flutter Linux bundle.
# Reuses the flatpak's .desktop / .metainfo.xml / icon — one set of metadata.
#
#   cd app_flutter && flutter build linux --release && cd ..
#   sudo apt install libmpv-dev patchelf     # (dnf: mpv-libs-devel patchelf)
#   APPIMAGETOOL=./appimagetool bash packaging/appimage/build.sh
#
# apt/ldconfig-based, unlike app_flutter/linux/bundle_libmpv.sh which downloads
# RPMs. That one makes a dev machine self-sufficient; this one ships.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
BUNDLE=$here/../../app_flutter/build/linux/x64/release/bundle
OUT=$PWD/aria-linux-x86_64.AppImage
APPIMAGETOOL=${APPIMAGETOOL:-appimagetool}
[ -x "$BUNDLE/aria" ] || { echo "no bundle at $BUNDLE — run flutter build linux --release first" >&2; exit 1; }

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
APPDIR=$work/AppDir
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" \
         "$APPDIR/usr/share/icons/hicolor/512x512/apps" "$APPDIR/usr/share/metainfo"

# The Flutter bundle goes in whole: `aria` already carries rpath $ORIGIN/lib
# (app_flutter/linux/CMakeLists.txt), and mpv_ffi.dart dlopens the literal path
# <dir of resolvedExecutable>/lib/libmpv.so — inside an AppImage that is
# <mountpoint>/usr/bin/lib/libmpv.so. No LD_LIBRARY_PATH, no AppRun trickery.
cp -a "$BUNDLE/." "$APPDIR/usr/bin/"

# libmpv + its non-base deps. Never ship the glibc family, the desktop stack or
# the graphics drivers: those must come from the host. This is not just size —
# libflutter_linux_gtk.so has RUNPATH $ORIGIN and sits in the very dir we fill,
# so a bundled copy CLAIMS the soname and the host's GTK then binds against it,
# dying at startup with a symbol lookup error. The clash check below enforces it.
# libmpv links the GL/GTK text stack for libplacebo's and libass's sake even in
# this audio-only app, so skipping them is safe. libvulkan is deliberately NOT
# skipped: it is a hard DT_NEEDED of libplacebo, nothing in-process links it,
# and it finds host ICDs through /usr/share/vulkan rather than by linking them.
SKIP='^(ld-linux|libc\.|libm\.|libdl|libpthread|librt\.|libresolv|libgcc_s|libstdc\+\+|libglib|libgobject|libgio|libgmodule|libgtk|libgdk|libX|libxcb|libwayland|libxkb|libsystemd|libudev|libdbus|libselinux|libmount|libblkid|libpcre|libffi\.|libz\.|libzstd|liblzma|libbz2|libGL|libEGL|libGLX|libGLdispatch|libOpenGL|libgbm|libdrm|libva|libvdpau|libcairo|libpango|libatk|libharfbuzz|libfreetype|libfontconfig|libpixman|libfribidi|libepoxy|libgraphite2|libthai|libdatrie)'

# ponytail: ldd's whole transitive closure, ~170 libs / ~200 MB unpacked. The
# distro libmpv drags in every optional ffmpeg dep (flite, lapack, rsvg, icu)
# that an audio-only player never touches, but they are NEEDED entries so it
# won't load without them. Ceiling: to halve it, build a trimmed libmpv the way
# packaging/flatpak/dev.aria.aria.yml does — ~10 min of CI for ~100 MB.
mpv=$(ldconfig -p | awk '/libmpv\.so\.[0-9]/{print $NF; exit}')
[ -n "$mpv" ] || { echo "libmpv not found — install libmpv-dev" >&2; exit 1; }
# Copied to the exact literal name mpv_ffi.dart dlopens; nothing here links it
# by soname, so no versioned name + symlink dance.
cp -L "$mpv" "$APPDIR/usr/bin/lib/libmpv.so"
libs=("$APPDIR/usr/bin/lib/libmpv.so")
while read -r name path; do
  case "$name" in
    # Same exemption as bundle_libmpv.sh: tiny X client libs mpv links that
    # desktop stacks often lack. Shipped despite the libX skip, never loaded
    # by the Flutter/GTK shell.
    libXss*|libXpresent*) ;;
    *) [[ $name =~ $SKIP ]] && continue ;;
  esac
  # Flutter's own libs share this dir — never clobber one.
  [ -e "$APPDIR/usr/bin/lib/$name" ] && continue
  cp -L "$path" "$APPDIR/usr/bin/lib/$name"
  libs+=("$APPDIR/usr/bin/lib/$name")
done < <(ldd "$mpv" | awk '/=> \//{print $1, $3}')

# The check that makes SKIP honest: nothing the Flutter shell resolves from the
# host may also be bundled, or our copy wins the soname and the host's GTK binds
# against the wrong one. Fails loudly here instead of crashing on a user's box.
clash=$(comm -12 \
  <({ patchelf --print-needed "$APPDIR/usr/bin/aria"
      patchelf --print-needed "$APPDIR/usr/bin/lib/libflutter_linux_gtk.so"; } | sort -u) \
  <(printf '%s\n' "${libs[@]##*/}" | sort -u))
[ -z "$clash" ] || { echo "bundled libs shadow the Flutter shell's own deps:" >&2
                     echo "$clash" >&2; exit 1; }

# $ORIGIN rpath so the bundled libs resolve each other before the host's. Only
# the ones just copied — Flutter's own already load via the binary's rpath.
for so in "${libs[@]}"; do patchelf --set-rpath '$ORIGIN' "$so"; done
echo "bundled libmpv + $(( ${#libs[@]} - 1 )) deps"

fp=$here/../flatpak
install -Dm644 "$fp/dev.aria.aria.desktop" "$APPDIR/dev.aria.aria.desktop"
install -Dm644 "$fp/dev.aria.aria.desktop" "$APPDIR/usr/share/applications/dev.aria.aria.desktop"
install -Dm644 "$fp/icon-512.png" "$APPDIR/dev.aria.aria.png"   # name must match the desktop file's Icon=
install -Dm644 "$fp/icon-512.png" "$APPDIR/usr/share/icons/hicolor/512x512/apps/dev.aria.aria.png"
install -Dm644 "$fp/dev.aria.aria.metainfo.xml" "$APPDIR/usr/share/metainfo/dev.aria.aria.metainfo.xml"
ln -sf dev.aria.aria.png "$APPDIR/.DirIcon"

cat > "$APPDIR/AppRun" <<'EOF'
#!/bin/sh
# ponytail: no GTK bundling, no LD_LIBRARY_PATH — the host supplies GTK/glib/GL
# and the app's own libs load via rpath $ORIGIN. Two ceilings: hosts older than
# the build runner's glibc, and the bundled audio client libs (pulse/pipewire/
# alsa) talking to an older host daemon. The flatpak is the answer for both.
exec "${APPDIR:-$(dirname "$(readlink -f "$0")")}/usr/bin/aria" "$@"
EOF
chmod +x "$APPDIR/AppRun"

# ponytail: -n skips appstreamcli validation — strictness varies by version and
# a cosmetic warning should not fail a release. Drop it to list Aria in an
# AppImage catalogue.
ARCH=${ARCH:-x86_64} "$APPIMAGETOOL" -n "$APPDIR" "$OUT"
echo "built $OUT"
