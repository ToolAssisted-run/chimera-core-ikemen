#!/usr/bin/env bash
# Builds Ikemen GO, with this core's patches and files, as a C archive:
#   build-ikemen.sh native              build/native/libikemen.a, Go: build/go-native
#   build-ikemen.sh guest -m <miniBox>  build/guest/libikemen.a,  Go: build/go-guest
#
# The source is a copy of the pinned submodule (extern/Ikemen-GO), never the
# submodule itself, with:
#   - patches/*.patch applied in order;
#   - go/chimera/* (the glue, the disk, the desktop helpers) added to its
#     package main, and the engine's own data/, external/ and font/ copied
#     under src/chimera_engine for the disk to carry;
#   - go/sdl2 put in place of SDL 2's Go binding (a replace directive).
# FFmpeg's binding (reisen) is Ikemen GO's own, over build-ffmpeg.sh's FFmpeg.
# Built with the tags chimera (the core's files), kinc (Ikemen GO's tag that
# leaves its Vulkan renderer out), netgo and osusergo (no C resolver).
#
# Needs: setup-go.sh, build-libxmp.sh <flavour>, build-ffmpeg.sh <flavour>, and Mesa's headers
# (setup-mesa.sh has unpacked build/mesa).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
flavour="${1:-}"
shift || true
minibox="${MINIBOX_DIR:-}"
while getopts "m:" opt; do
	case "$opt" in
		m) minibox="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
case "$flavour" in native | guest) ;; *) echo "usage: $0 native|guest [-m <miniBox>]" >&2; exit 2 ;; esac
[ -n "$minibox" ] || { echo "ikemen: needs -m <miniBox checkout> (its guest kit headers)" >&2; exit 1; }
minibox="$(cd "$minibox" && pwd)"

goroot="$root/build/go-$flavour"
[ -x "$goroot/bin/go" ] || { echo "ikemen: run setup-go.sh first" >&2; exit 1; }
xmp="$root/build/libxmp-$flavour"
[ -f "$xmp/lib/libxmp.a" ] || { echo "ikemen: run build-libxmp.sh $flavour first" >&2; exit 1; }
ffmpeg="$root/build/ffmpeg-$flavour"
[ -f "$ffmpeg/lib/libavcodec.a" ] || { echo "ikemen: run build-ffmpeg.sh $flavour first" >&2; exit 1; }
mesa_inc="$root/build/mesa/include"
[ -f "$mesa_inc/GL/osmesa.h" ] || { echo "ikemen: Mesa's headers are not unpacked (run setup-mesa.sh)" >&2; exit 1; }

src="$root/build/ikemen-src"
out="$root/build/$flavour"
mkdir -p "$out"

# a fresh copy of the pinned source, patched, with the core's files
rm -rf "$src"
mkdir -p "$src"
git -C "$root/extern/Ikemen-GO" archive HEAD | tar -x -C "$src"
for p in "$root"/patches/*.patch; do
	patch -d "$src" -p1 --quiet < "$p" || { echo "ikemen: $(basename "$p") does not apply" >&2; exit 1; }
done
cp "$root"/go/chimera/* "$src/src/"
mkdir -p "$src/src/chimera_engine"
cp -r "$src/data" "$src/external" "$src/font" "$src/src/chimera_engine/"

export GOROOT="$goroot" PATH="$goroot/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-mod=mod
export GOPATH="${CHIMERA_GOPATH:-$root/build/gopath}" GOCACHE="$root/build/gocache-$flavour"
(
	cd "$src"
	go mod edit -replace "github.com/veandco/go-sdl2=$root/go/sdl2"
)

kit="-I$minibox/source/guest/include -I$minibox/extern/jsmn -I$mesa_inc -I$xmp/include"
# go-gl asks pkg-config for OpenGL: the answer is the core's own (pkgconfig/gl.pc);
# reisen asks it for FFmpeg's libraries: build-ffmpeg.sh's
export PKG_CONFIG_PATH="$here/pkgconfig:$ffmpeg/lib/pkgconfig" PKG_CONFIG_LIBDIR="$here/pkgconfig:$ffmpeg/lib/pkgconfig"
if [ "$flavour" = native ]; then
	export CC=gcc
	export CGO_CFLAGS="-O2 -fcf-protection=none -I$here/native-shim $kit"
else
	sr="$minibox/build/meson-cpp/guest-sysroot"
	[ -f "$sr/lib/musl-gcc.specs" ] || { echo "ikemen: miniBox's meson-cpp guest sysroot is not built" >&2; exit 1; }
	cat > "$out/guest-cc" <<CC
#!/bin/sh
exec gcc -specs=$sr/lib/musl-gcc.specs -mno-red-zone -fno-stack-protector -mstack-protector-guard=global -fcf-protection=none "\$@"
CC
	chmod +x "$out/guest-cc"
	export CC="$out/guest-cc"
	# guest-compat: the X11 types Mesa's glx.h names (go-gl includes it)
	export CGO_CFLAGS="-O2 -DCHIMERA_GUEST -I$minibox/extern/emulibc -I$here/guest-compat $kit"
fi
export CGO_LDFLAGS="-L$xmp/lib"
export CGO_ENABLED=1
# Ikemen GO's rollback uses Go's arena package (its build.sh sets the same)
export GOEXPERIMENT=arenas

(
	cd "$src"
	go build -buildmode=c-archive -trimpath -tags chimera,kinc,netgo,osusergo \
		-ldflags "-X main.Version=v1.0.0-chimera" -o "$out/libikemen.a" ./src
)
echo "ikemen: built $out/libikemen.a"
