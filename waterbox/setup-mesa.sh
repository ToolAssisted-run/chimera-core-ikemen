#!/usr/bin/env bash
# Builds the OpenGL this core draws through: Mesa's llvmpipe driver behind
# the gallium OSMesa front end - twice, from one pinned tarball with one set
# of options: once cross-built for the miniBox guest, once for the host.
#
# Godot's Compatibility renderer draws with OpenGL 3.3, and there is no GPU
# inside a sandbox, so the core brings its own OpenGL. llvmpipe turns each
# shader into machine code with LLVM (build-llvm.sh), where softpipe, the
# other software driver, interprets it pixel by pixel and was most of every
# frame's time. llvmpipe is told of one CPU on every computer (patch
# mesa-patches/0001: an x86-64 with SSE2, one processor), so the code it
# makes, and every picture, is the same everywhere, and it starts no threads.
#
# Why the host gets the SAME Mesa: a game can ask its OpenGL questions
# (glGetString, the limits, reading pixels back) and act on the answers, so
# the OpenGL is part of the machine. The native reference has to answer as
# the sandbox does, or the two builds stop being the same machine.
#
# The recipe started as chimera-core-rsdkv4's (Mesa 24.0.9, the same SHA256),
# with LLVM added.
#
# Produces:  build/mesa/build-guest2/  the *.a archives plus the gallium osmesa
#                                      target.c.o that the guest build links;
#            build/mesa/build-native/  the same for the host, with libOSMesa.so.
#
# Usage: ./setup-mesa.sh [-n] [-m <miniBox dir>] [-j N]
#   -n                             build the host flavour (no miniBox needed)
#   MESA_TARBALL=<path>            use a tarball already on this machine
#   MESA_BUILD_CONFIGURE_ONLY=1    validate the recipe without the ~15min compile
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
minibox="${MINIBOX_DIR:-}"
jobs="$(nproc)"
native=0
while getopts "nm:j:" opt; do
	case "$opt" in
		n) native=1 ;;
		m) minibox="$OPTARG" ;;
		j) jobs="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

version="24.0.9"
sha256="51aa686ca4060e38711a9e8f60c8f1efaa516baf411946ed7f2c265cd582ca4c"
url="https://archive.mesa3d.org/mesa-$version.tar.xz"

mesa="$root/build/mesa"
if [ "$native" = 1 ]; then
	build="$mesa/build-native"
else
	build="$mesa/build-guest2"
fi
cache="${CHIMERA_DEPS_DIR:-$root/build/deps}"
tarball="${MESA_TARBALL:-$cache/mesa-$version.tar.xz}"

if [ -d "$build" ] && find "$build" -name '*.a' -print -quit 2>/dev/null | grep -q . \
	&& find "$build/src/gallium/targets/osmesa" -name 'target.c.o' -print -quit 2>/dev/null | grep -q .; then
	echo "mesa: already built in $build"
	exit 0
fi

if [ "$native" = 0 ]; then
	[ -n "$minibox" ] || { echo "mesa: the guest flavour needs -m <miniBox dir> (or MINIBOX_DIR)" >&2; exit 1; }
	minibox="$(cd "$minibox" && pwd)"
	# The guest sysroot must be the C++ (meson-cpp) one: it carries libstdc++
	# and the C++ headers the C-only meson-linux sysroot lacks.
	sr="$minibox/build/meson-cpp/guest-sysroot"
	[ -f "$sr/lib/musl-gcc.specs" ] || { echo "guest sysroot not built at $sr (build miniBox's meson-cpp first)" >&2; exit 1; }
	gccver="$(basename "$(ls -d "$sr"/include/c++/* | head -1)")"
fi

if [ ! -f "$tarball" ]; then
	mkdir -p "$cache"
	echo "mesa: fetching $url"
	curl -fL --retry 3 -o "$tarball.part" "$url"
	mv "$tarball.part" "$tarball"
fi
echo "$sha256  $tarball" | sha256sum -c - >/dev/null || {
	echo "mesa: the tarball is not the release this core is pinned to" >&2
	exit 1
}

if [ ! -d "$mesa/src/gallium" ]; then
	mkdir -p "$mesa"
	tar -xf "$tarball" -C "$mesa" --strip-components=1
	for p in "$here"/mesa-patches/*.patch; do
		[ -f "$p" ] || continue
		echo "mesa: applying $(basename "$p")"
		patch -d "$mesa" -p1 --quiet < "$p"
	done
fi
# a tree extracted before the patches were there is not this Mesa
for p in "$here"/mesa-patches/*.patch; do
	[ -f "$p" ] || continue
	patch -d "$mesa" -p1 --dry-run -R --quiet < "$p" > /dev/null 2>&1 || {
		echo "mesa: $mesa lacks $(basename "$p"); remove build/mesa and run again" >&2
		exit 1
	}
done

# LLVM for llvmpipe (build-llvm.sh): its llvm-config, which for the guest
# answers with the guest build's folders
llvm_native="$root/build/llvm-native"
[ -x "$llvm_native/bin/llvm-config" ] || { echo "mesa: build LLVM first (waterbox/build-llvm.sh native, and guest for the guest)" >&2; exit 1; }

# Prefer a system meson that already has what Mesa needs; fall back to a
# private venv. Mesa's version check needs `packaging` (3.12 dropped
# distutils); mako generates the GL dispatch.
meson=""
if command -v meson >/dev/null && python3 -c "import mako, packaging" 2>/dev/null; then
	meson="$(command -v meson)"
else
	venv="${MESA_BUILD_VENV:-$root/build/mesa-build-venv}"
	if [ ! -x "$venv/bin/meson" ]; then
		python3 -m venv "$venv" || {
			echo "mesa: no usable meson - install python3-venv, or meson plus python3-mako" >&2
			exit 1
		}
		"$venv/bin/pip" -q install --upgrade pip
		"$venv/bin/pip" -q install meson ninja mako packaging
	fi
	meson="$venv/bin/meson"
fi

# softpipe + gallium OSMesa, no LLVM, nothing that pulls a host lib.
# -Dshared-glapi=disabled is ESSENTIAL for the guest: otherwise
# _glapi_tls_Context lands only in a .so this core cannot link. zlib/expat are
# vendored via wraps.
opts="-Dforce_fallback_for=zlib,expat -Dgallium-drivers=swrast -Dvulkan-drivers= \
  -Dllvm=enabled -Dshared-llvm=disabled -Dosmesa=true -Dopengl=true -Dglx=disabled -Degl=disabled \
  -Dgbm=disabled -Dglvnd=false -Dplatforms= -Dgles1=disabled -Dgles2=disabled \
  -Ddefault_library=static -Dbuild-tests=false -Dzstd=disabled -Dshared-glapi=disabled"

# Neither flavour may see the host's optional libraries: the guest because it
# cannot link them, the host because then the two would not be the same Mesa.
# (Without this mesa's pkg-config finds the host libdrm and util/u_screen.c
# includes xf86drm.h, which no guest sysroot has.)
mkdir -p "$mesa/no-pkgconfig"
PKG_CONFIG_LIBDIR="$mesa/no-pkgconfig"
PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

if [ "$native" = 1 ]; then
	cat > "$mesa/native.ini" <<NATIVEINI
[binaries]
llvm-config = '$llvm_native/bin/llvm-config'

[built-in options]
c_args = ['-DCHIMERA_PINNED_CPU', '-fcf-protection=none']
cpp_args = ['-DCHIMERA_PINNED_CPU', '-fcf-protection=none']
NATIVEINI
	setup_args="--native-file $mesa/native.ini"
else
	llvm_guest="$root/build/llvm-guest"
	[ -f "$llvm_guest/.chimera-built" ] || { echo "mesa: build the guest LLVM first (waterbox/build-llvm.sh guest)" >&2; exit 1; }
	# the native llvm-config, answering with the guest LLVM's folders
	printf '#!/bin/sh\nout="$("%s/bin/llvm-config" "$@")" || exit $?\nprintf "%%s\\n" "$out" | sed "s|%s|%s|g"\n' \
		"$llvm_native" "$llvm_native" "$llvm_guest" > "$mesa/llvm-config-guest"
	chmod +x "$mesa/llvm-config-guest"
	# single-`-specs` wrapper compilers: passing -specs through meson's *_args
	# doubles it and the specs file errors, so the flag rides inside the compiler.
	cat > "$mesa/gw-cc"  <<EOF
#!/bin/sh
exec gcc "\$@" -specs $sr/lib/musl-gcc.specs
EOF
	cat > "$mesa/gw-cxx" <<EOF
#!/bin/sh
exec g++ "\$@" -specs $sr/lib/musl-gcc.specs
EOF
	chmod +x "$mesa/gw-cc" "$mesa/gw-cxx"

	# Kernel uapi headers, as a LAST-RESORT include path. The guest compiles
	# with -nostdinc plus the musl sysroot (from the specs), and musl ships no
	# linux/, asm/ or asm-generic/ headers - but mesa's include/drm-uapi/drm.h
	# includes <linux/types.h>. The directory below holds nothing but symlinks
	# to those three kernel trees and is passed with -idirafter, which is
	# searched AFTER the sysroot: musl still wins for every header it provides.
	uapi="$mesa/uapi-include"
	mkdir -p "$uapi"
	ln -sfn /usr/include/linux "$uapi/linux"
	ln -sfn /usr/include/asm-generic "$uapi/asm-generic"
	if [ -d /usr/include/x86_64-linux-gnu/asm ]; then
		ln -sfn /usr/include/x86_64-linux-gnu/asm "$uapi/asm"
	elif [ -d /usr/include/asm ]; then
		ln -sfn /usr/include/asm "$uapi/asm"
	fi

	# large code model, static reloc, no %fs stack guard, the guest's own
	# libstdc++.
	cat > "$mesa/guest-cross.ini" <<EOF
[binaries]
c = '$mesa/gw-cc'
cpp = '$mesa/gw-cxx'
ar = 'ar'
strip = 'strip'
pkg-config = 'pkg-config'
llvm-config = '$mesa/llvm-config-guest'

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true

[built-in options]
c_args = ['-DCHIMERA_PINNED_CPU', '-mcmodel=large', '-mstack-protector-guard=global', '-fno-stack-protector', '-fno-pic', '-fno-pie', '-fcf-protection=none', '-idirafter', '$uapi']
cpp_args = ['-DCHIMERA_PINNED_CPU', '-mcmodel=large', '-mstack-protector-guard=global', '-fno-stack-protector', '-fno-pic', '-fno-pie', '-fcf-protection=none', '-fexceptions', '-I$sr/include/c++/$gccver', '-I$sr/include/c++/$gccver/x86_64-linux-musl', '-idirafter', '$uapi']
EOF
	setup_args="--cross-file $mesa/guest-cross.ini"
fi

if [ -f "$build/build.ninja" ]; then
	"$meson" setup --reconfigure "$build" "$mesa" $setup_args $opts
else
	"$meson" setup "$build" "$mesa" $setup_args $opts
fi

[ "${MESA_BUILD_CONFIGURE_ONLY:-}" = 1 ] && { echo "mesa: configured OK (configure-only)"; exit 0; }

# Mesa's final shared osmesa .so fails to link (for the guest: __dso_handle,
# -fno-pic, the large model; for both: LLVM is built without PIC) - EXPECTED.
# The core links the static archives plus the target's own object, built
# before that step, so a failure is tolerated when nothing but that .so is
# left to build.
compile_log="$build/chimera-compile.log"
if ! "$meson" compile -C "$build" -j "$jobs" > "$compile_log" 2>&1; then
	# keep going past the .so, then see what else failed
	ninja -C "$build" -k 0 -j "$jobs" >> "$compile_log" 2>&1 || true
	others="$(grep '^FAILED:' "$compile_log" | grep -vc 'libOSMesa' || true)"
	if [ "$others" != 0 ]; then
		grep -A20 '^FAILED:' "$compile_log" | grep -v libOSMesa | head -40 >&2
		echo "mesa: the build failed ($others failed steps besides the osmesa library; $compile_log)" >&2
		exit 1
	fi
	echo "mesa: only the osmesa shared library did not link, as expected"
fi

target_o="$(find "$build/src/gallium/targets/osmesa" -name 'target.c.o' 2>/dev/null | head -1)"
archives="$(find "$build" -name '*.a' 2>/dev/null | wc -l)"
if [ -n "$target_o" ] && [ "$archives" -gt 0 ]; then
	echo "mesa: ready - $archives archives + $target_o"
else
	echo "mesa: the build did NOT produce the osmesa target.c.o / archives" >&2
	exit 1
fi
