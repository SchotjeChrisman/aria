# Vendored copy of media_kit_libs_macos_audio 1.1.4, changed in exactly two
# places: the flavor is audio-encodersgpl instead of audio-default, and the
# checksum matches. Reason: upstream's audio-default builds ffmpeg with
# `--disable-all --enable-filter=equalizer --enable-filter=overlay`, so the
# `volume`, `lowshelf`, `highshelf`, `highpass`, `lowpass`, `bandpass` and
# `bandreject` filters that core/eq.dart emits do not exist. libavfilter graph
# parsing is all-or-nothing, so one missing filter dropped the whole EQ chain
# AND aborted the load — headphone EQ killed playback on macOS. The
# encodersgpl flavor is the same mpv 0.36.0 / -Dgpl=false / -Dcoreaudio=enabled
# build with ffmpeg `--enable-filters` (and --enable-version3, not
# --enable-gpl, so it stays LGPL). Frameworks grow ~17MB -> ~40MB.
# ponytail: vendored rather than forked upstream — two lines beat a fork.
# Upgrade path: drop this override if media_kit ever ships a filters-enabled
# audio build.

all: Frameworks/*.xcframework Frameworks/.symlinks

MPV_XCFRAMEWORKS_VERSION=v0.6.0
MPV_XCFRAMEWORKS_SHA256SUM=56b83f14b795a9c7557f5469ea1903e53c94380bd8631180c47de33134397731

.cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz:
	mkdir -p .cache/xcframeworks
	rm -f .cache/xcframeworks/*.tmp .cache/xcframeworks/*-macos-universal.tar.gz
	curl -L \
		https://github.com/media-kit/libmpv-darwin-build/releases/download/${MPV_XCFRAMEWORKS_VERSION}/libmpv-xcframeworks_${MPV_XCFRAMEWORKS_VERSION}_macos-universal-audio-encodersgpl.tar.gz \
		-o .cache/xcframeworks/libmpv.tar.gz.tmp
	shasum -a 256 -c <<< '${MPV_XCFRAMEWORKS_SHA256SUM}  .cache/xcframeworks/libmpv.tar.gz.tmp'
	mv .cache/xcframeworks/libmpv.tar.gz.tmp .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz
	touch .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz

.cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz: .cache/xcframeworks/libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz
	rm -f .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz
	ln -s libmpv-xcframeworks-${MPV_XCFRAMEWORKS_VERSION}-macos-universal.tar.gz .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz

Frameworks/*.xcframework: .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz
	mkdir -p Frameworks
	rm -rf Frameworks/*.xcframework
	tar -xvf .cache/xcframeworks/libmpv-xcframeworks-macos-universal.tar.gz --strip-components 1 -C Frameworks
	touch Frameworks/*.xcframework

Frameworks/.symlinks: Frameworks/*.xcframework
	rm -rf Frameworks/.symlinks
	mkdir -p Frameworks/.symlinks/mpv
	sed -i '' 's/\r$$//g' create_framework_symlinks.sh # remove CRLF line terminator added by Flutter packaging (https://github.com/media-kit/media-kit/issues/338)
	sh create_framework_symlinks.sh Frameworks/Mpv.xcframework Frameworks/.symlinks/mpv

.PHONY: clean
clean:
	rm -rf .cache
	rm -f ./Headers/mpv/*.h
	rm -rf ./Frameworks/*.xcframework
