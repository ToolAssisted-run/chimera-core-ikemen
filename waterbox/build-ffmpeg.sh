#!/usr/bin/env bash
# Builds FFmpeg, which plays Ikemen GO's background videos, as static
# libraries, with libvpx inside it:
#   build-ffmpeg.sh native            for the native reference
#   build-ffmpeg.sh guest -m <miniBox> for the sandbox
# Produces build/ffmpeg-<flavour>/lib/*.a, include/ and lib/pkgconfig/ (the
# reisen binding asks pkg-config for FFmpeg).
#
# What is built is what Ikemen GO's own releases build (its build/build.sh):
# FFmpeg 7.1 under the LGPL, reading Matroska and WebM files, decoding VP8 and
# VP9 through libvpx (only libvpx's decoders read a WebM video's transparency)
# and Opus and Vorbis sound, with the scale, pad, crop and format filters.
#
# On top of that, every computer must decode a video to the same bytes, as a
# movie depends on it:
#   - no assembly (FFmpeg --disable-asm, libvpx's generic C target): which
#     hand-written code a library picks depends on the processor, and the
#     float code for sound and the picture scaler does not round as the C does;
#   - no threads (FFmpeg --disable-pthreads, libvpx --disable-multithread).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
flavour="${1:-}"
shift || true
minibox="${MINIBOX_DIR:-}"
jobs="$(nproc)"
while getopts "m:j:" opt; do
	case "$opt" in
		m) minibox="$OPTARG" ;;
		j) jobs="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
case "$flavour" in native | guest) ;; *) echo "usage: $0 native|guest [-m <miniBox>]" >&2; exit 2 ;; esac

ffmpeg_version="7.1.5"
ffmpeg_sha256="de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f"
ffmpeg_url="https://ffmpeg.org/releases/ffmpeg-$ffmpeg_version.tar.xz"
vpx_version="1.15.2"
vpx_sha256="26fcd3db88045dee380e581862a6ef106f49b74b6396ee95c2993a260b4636aa"
vpx_url="https://github.com/webmproject/libvpx/archive/refs/tags/v$vpx_version.tar.gz"

cache="${CHIMERA_DEPS_DIR:-$root/build/deps}"
out="$root/build/ffmpeg-$flavour"
work="$root/build/ffmpeg-$flavour-work"

if [ -f "$out/lib/libavcodec.a" ]; then
	echo "ffmpeg: already built in $out"
	exit 0
fi

fetch() { # <url> <file> <sha256>
	if [ ! -f "$cache/$2" ]; then
		mkdir -p "$cache"
		echo "ffmpeg: fetching $1"
		curl -fL --retry 3 -o "$cache/$2.part" "$1"
		mv "$cache/$2.part" "$cache/$2"
	fi
	echo "$3  $cache/$2" | sha256sum -c - > /dev/null || { echo "ffmpeg: $2 is not the release this core is pinned to" >&2; exit 1; }
}
fetch "$ffmpeg_url" "ffmpeg-$ffmpeg_version.tar.xz" "$ffmpeg_sha256"
fetch "$vpx_url" "libvpx-$vpx_version.tar.gz" "$vpx_sha256"

rm -rf "$work"
mkdir -p "$work/ffmpeg-src" "$work/vpx-src" "$work/vpx" "$work/ffmpeg"
tar -xJf "$cache/ffmpeg-$ffmpeg_version.tar.xz" -C "$work/ffmpeg-src" --strip-components=1
tar -xzf "$cache/libvpx-$vpx_version.tar.gz" -C "$work/vpx-src" --strip-components=1

cflags="-fcf-protection=none"
if [ "$flavour" = guest ]; then
	[ -n "$minibox" ] || { echo "ffmpeg: the guest flavour needs -m <miniBox checkout>" >&2; exit 1; }
	sr="$(cd "$minibox" && pwd)/build/meson-cpp/guest-sysroot"
	[ -f "$sr/lib/musl-gcc.specs" ] || { echo "ffmpeg: miniBox's meson-cpp guest sysroot is not built" >&2; exit 1; }
	# the guest's compiler, as guest-toolchain.cmake has it
	cat > "$work/cc" <<CC
#!/bin/sh
exec gcc -specs=$sr/lib/musl-gcc.specs -mcmodel=large -mno-red-zone -mstack-protector-guard=global -fno-stack-protector -fno-pic -fno-pie "\$@"
CC
	chmod +x "$work/cc"
	cc="$work/cc"
	cross=(--enable-cross-compile --target-os=linux --arch=x86_64)
else
	cc=gcc
	cross=()
fi

# libvpx: the decoders only, plain C
(
	cd "$work/vpx"
	CC="$cc" "$work/vpx-src/configure" --prefix="$out" --target=generic-gnu \
		--enable-static --disable-shared --disable-multithread --disable-runtime-cpu-detect \
		--disable-examples --disable-tools --disable-docs --disable-unit-tests \
		--disable-install-bins --disable-install-docs \
		--disable-vp8-encoder --disable-vp9-encoder --enable-vp8-decoder --enable-vp9-decoder \
		--disable-webm-io --disable-libyuv \
		--extra-cflags="$cflags" > configure.log 2>&1 || { tail -30 configure.log >&2; exit 1; }
	make -j"$jobs" > make.log 2>&1 || { tail -30 make.log >&2; exit 1; }
	make install > install.log 2>&1
)

# FFmpeg, finding libvpx through its pkg-config file and nothing of the host's
export PKG_CONFIG_PATH="$out/lib/pkgconfig" PKG_CONFIG_LIBDIR="$out/lib/pkgconfig"
(
	cd "$work/ffmpeg"
	"$work/ffmpeg-src/configure" --prefix="$out" --cc="$cc" --extra-cflags="$cflags" "${cross[@]}" \
		--pkg-config=pkg-config --pkg-config-flags=--static \
		--enable-static --disable-shared --disable-gpl --disable-nonfree \
		--disable-debug --disable-doc --disable-programs --disable-everything --disable-autodetect \
		--disable-network --disable-avdevice \
		--enable-avformat --enable-avcodec --enable-avutil --enable-swresample --enable-swscale \
		--enable-avfilter --enable-filter=buffer,buffersink,format,scale,pad,crop \
		--enable-libvpx \
		--enable-demuxer=matroska \
		--enable-decoder=libvpx_vp8,libvpx_vp9,opus,vorbis \
		--enable-parser=vp8,vp9,opus,vorbis \
		--disable-asm --disable-inline-asm --disable-x86asm --disable-runtime-cpudetect \
		--disable-pthreads --disable-w32threads --disable-os2threads \
		--disable-iconv --disable-zlib --disable-bzlib --disable-lzma \
		> configure.log 2>&1 || { tail -30 configure.log >&2; exit 1; }
	# FFmpeg only warns when a decoder it was asked for cannot be built
	for d in LIBVPX_VP8_DECODER LIBVPX_VP9_DECODER OPUS_DECODER VORBIS_DECODER MATROSKA_DEMUXER; do
		grep -q "^#define CONFIG_$d 1" config_components.h || { echo "ffmpeg: configured without $d" >&2; exit 1; }
	done
	make -j"$jobs" > make.log 2>&1 || { tail -30 make.log >&2; exit 1; }
	make install > install.log 2>&1
)
echo "ffmpeg: built $out ($(cd "$out/lib" && ls *.a | tr '\n' ' '))"
