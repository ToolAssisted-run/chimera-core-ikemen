#!/usr/bin/env bash
# Builds libxmp, which plays module music (MOD, XM, S3M, IT) for Ikemen GO,
# from one pinned release, as a static library:
#   build-libxmp.sh native            for the native reference
#   build-libxmp.sh guest -m <miniBox> for the sandbox
# Produces build/libxmp-<flavour>/lib/libxmp.a and include/xmp.h.
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

version="4.7.4"
sha256="a25583aa3b031c78ba0b4e83387fa596fb05742622e60f60d1540ee2af79b8d9"
url="https://github.com/libxmp/libxmp/releases/download/libxmp-$version/libxmp-$version.tar.gz"
cache="${CHIMERA_DEPS_DIR:-$root/build/deps}"
tarball="$cache/libxmp-$version.tar.gz"
src="$root/build/libxmp-src"
out="$root/build/libxmp-$flavour"

if [ -f "$out/lib/libxmp.a" ]; then
	echo "libxmp: already built in $out"
	exit 0
fi
if [ ! -f "$tarball" ]; then
	mkdir -p "$cache"
	echo "libxmp: fetching $url"
	curl -fL --retry 3 -o "$tarball.part" "$url"
	mv "$tarball.part" "$tarball"
fi
echo "$sha256  $tarball" | sha256sum -c - > /dev/null || { echo "libxmp: the tarball is not the release this core is pinned to" >&2; exit 1; }
if [ ! -f "$src/CMakeLists.txt" ]; then
	rm -rf "$src"
	mkdir -p "$src"
	tar -xzf "$tarball" -C "$src" --strip-components=1
fi

opts=(-DBUILD_STATIC=ON -DBUILD_SHARED=OFF -DBUILD_LITE=OFF -DWITH_UNIT_TESTS=OFF -DCMAKE_BUILD_TYPE=Release
	-DCMAKE_INSTALL_PREFIX="$out" -DCMAKE_INSTALL_LIBDIR=lib)
case "$flavour" in
	native)
		cmake -G Ninja -S "$src" -B "$out/build" "${opts[@]}" -DCMAKE_C_FLAGS="-fcf-protection=none"
		;;
	guest)
		[ -n "$minibox" ] || { echo "libxmp: the guest flavour needs -m <miniBox checkout>" >&2; exit 1; }
		export MINIBOX_SYSROOT="$(cd "$minibox" && pwd)/build/meson-cpp/guest-sysroot"
		cmake -G Ninja -S "$src" -B "$out/build" "${opts[@]}" -DCMAKE_TOOLCHAIN_FILE="$here/guest-toolchain.cmake"
		;;
esac
ninja -C "$out/build" -j "$jobs" install > /dev/null
echo "libxmp: built $out"
