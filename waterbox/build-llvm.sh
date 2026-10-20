#!/usr/bin/env bash
# Builds LLVM 18.1.8 for Mesa's llvmpipe (setup-mesa.sh), which turns
# Godot's shaders into machine code instead of interpreting them pixel by
# pixel as softpipe does:
#   build-llvm.sh native             for this computer (the native reference),
#                                    and the table generator the guest needs
#   build-llvm.sh guest -m <miniBox> for the sandbox
# X86 only, no threads (the machine's scheduler is the only one), static,
# RTTI on (Mesa's C++ needs it to match), no compression or terminal
# libraries. Both flavours are built WITHOUT CET (-fcf-protection=none): LLVM
# puts endbr64 into the code it generates when it was itself compiled with
# CET, and the code both flavours generate must be the same bytes (learnt in
# chimera-core-rpcs3, whose build-llvm.sh this follows).
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

version="18.1.8"
sha256="0b58557a6d32ceee97c8d533a59b9212d87e0fc4d2833924eb6c611247db2f2a"
url="https://github.com/llvm/llvm-project/releases/download/llvmorg-$version/llvm-project-$version.src.tar.xz"
cache="${CHIMERA_DEPS_DIR:-$root/build/deps}"
tarball="$cache/llvm-project-$version.src.tar.xz"
src="$root/build/llvm-src"
out="$root/build/llvm-$flavour"

case "$flavour" in native | guest) ;; *) echo "usage: $0 native|guest [-m <miniBox>] [-j N]" >&2; exit 2 ;; esac

if [ -f "$out/.chimera-built" ]; then
	echo "llvm: already built in $out"
	exit 0
fi
if [ ! -f "$tarball" ]; then
	mkdir -p "$cache"
	echo "llvm: fetching $url"
	curl -fL --retry 3 -o "$tarball.part" "$url"
	mv "$tarball.part" "$tarball"
fi
echo "$sha256  $tarball" | sha256sum -c - > /dev/null || { echo "llvm: the tarball is not the release this core is pinned to" >&2; exit 1; }
if [ ! -f "$src/llvm/CMakeLists.txt" ]; then
	rm -rf "$src"
	mkdir -p "$src"
	tar -xf "$tarball" -C "$src" --strip-components=1
fi

common=(
	-DLLVM_TARGETS_TO_BUILD=X86 -DLLVM_ENABLE_THREADS=OFF -DBUILD_SHARED_LIBS=OFF
	-DLLVM_BUILD_LLVM_DYLIB=OFF -DLLVM_LINK_LLVM_DYLIB=OFF -DLLVM_ENABLE_ASSERTIONS=OFF
	-DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_TERMINFO=OFF
	-DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_LIBPFM=OFF -DLLVM_ENABLE_BINDINGS=OFF -DLLVM_ENABLE_OCAMLDOC=OFF
	-DLLVM_INCLUDE_TESTS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_DOCS=OFF
	-DLLVM_ENABLE_WARNINGS=OFF -DLLVM_ENABLE_RTTI=ON -DLLVM_ENABLE_EH=OFF
	-DLLVM_USE_INTEL_JITEVENTS=OFF -DLLVM_USE_PERF=OFF -DLLVM_ENABLE_PIC=OFF
	-DCMAKE_BUILD_TYPE=Release
)

case "$flavour" in
	native)
		cmake -G Ninja -S "$src/llvm" -B "$out" "${common[@]}" \
			-DLLVM_INCLUDE_UTILS=ON -DLLVM_BUILD_UTILS=OFF -DLLVM_INCLUDE_TOOLS=ON -DLLVM_BUILD_TOOLS=OFF \
			-DCMAKE_C_FLAGS="-fcf-protection=none" -DCMAKE_CXX_FLAGS="-fcf-protection=none"
		ninja -C "$out" -j "$jobs" llvm-tblgen llvm-config
		ninja -C "$out" -j "$jobs"
		;;
	guest)
		[ -n "$minibox" ] || { echo "llvm: the guest flavour needs -m <miniBox checkout>" >&2; exit 1; }
		minibox="$(cd "$minibox" && pwd)"
		native="$root/build/llvm-native"
		[ -x "$native/bin/llvm-tblgen" ] || { echo "llvm: build the native flavour first (its llvm-tblgen)" >&2; exit 1; }
		export MINIBOX_SYSROOT="$minibox/build/meson-cpp/guest-sysroot"
		cmake -G Ninja -S "$src/llvm" -B "$out" "${common[@]}" -DCMAKE_TOOLCHAIN_FILE="$here/guest-toolchain.cmake" \
			-DLLVM_INCLUDE_UTILS=OFF -DLLVM_INCLUDE_TOOLS=OFF -DLLVM_BUILD_TOOLS=OFF \
			-DLLVM_TABLEGEN="$native/bin/llvm-tblgen" -DLLVM_NATIVE_TOOL_DIR="$native/bin" \
			-DLLVM_HOST_TRIPLE=x86_64-linux-musl -DLLVM_DEFAULT_TARGET_TRIPLE=x86_64-linux-musl \
			-DCMAKE_CROSSCOMPILING=ON -DHAVE_LIBPTHREAD=ON
		# the libraries only: LLVM's own programs are not for the sandbox
		# shellcheck disable=SC2046
		ninja -C "$out" -j "$jobs" $(ninja -C "$out" -t targets all | sed -n 's/^\(lib\/libLLVM[^:]*\.a\): .*/\1/p')
		;;
esac
touch "$out/.chimera-built"
echo "llvm: built $out"
