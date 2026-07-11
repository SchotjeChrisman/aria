# Aria Flatpak

Self-contained package: bundles **libmpv** (built from source against the
freedesktop 25.08 runtime) so `media_kit` plays audio on any machine without a
system-installed mpv.

## One-time prerequisites

```sh
sudo dnf install -y flatpak-builder
flatpak install -y flathub org.freedesktop.Sdk//25.08 \
                           org.freedesktop.Platform.codecs-extra//25.08
```

If the filtered Fedora flathub can't find the Sdk, unfilter it once:
`flatpak remote-modify --system --no-filter flathub`.

## Build & run

```sh
# 1. Build the Flutter release bundle (the manifest packages it)
cd app_flutter && flutter build linux --release && cd ..

# 2. Build + install the flatpak
flatpak-builder --user --install --force-clean \
  build-flatpak packaging/flatpak/dev.aria.aria.yml

# 3. Run
flatpak run dev.aria.aria
```

Rebuild after app changes: re-run steps 1–2. The libplacebo/mpv modules are
cached by flatpak-builder, so only the app module rebuilds.
