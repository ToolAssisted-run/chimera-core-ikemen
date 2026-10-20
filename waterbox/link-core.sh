#!/usr/bin/env bash
# Links the core from what build-ikemen.sh, build-libxmp.sh and setup-mesa.sh
# built:
#
#   native  build/native/run-native: the native reference, the core's calls
#           driven by run-native.c, with the sandbox's math (make-native-libm.sh);
#   guest   build/guest/core.wbx: the core, checked by miniBox's check-wbx.sh,
#           and build/guest/run-wbx, which drives it in the sandbox.
#
# Usage: ./link-core.sh native|guest -m <miniBox checkout>
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
[ -n "$minibox" ] || { echo "link-core: pass -m <miniBox checkout>" >&2; exit 2; }
minibox="$(cd "$minibox" && pwd)"

ikemen_libs() {
	# Ikemen GO and the glue (build-ikemen.sh), whole: the core's calls are in
	# it and nothing else asks for them; then libxmp
	local lib="$root/build/$1/libikemen.a"
	[ -f "$lib" ] || { echo "link-core: no $lib (run build-ikemen.sh $1)" >&2; exit 1; }
	echo "-Wl,--whole-archive $lib -Wl,--no-whole-archive $root/build/libxmp-$1/lib/libxmp.a"
}
llvm_libs() {
	# llvmpipe's LLVM (build-llvm.sh), every library; only what Mesa calls is linked
	local dir="$root/build/llvm-$1/lib"
	ls "$dir"/libLLVM*.a > /dev/null 2>&1 || { echo "link-core: no LLVM in $dir (run build-llvm.sh $1)" >&2; exit 1; }
	ls "$dir"/libLLVM*.a | sort
}
mesa_parts() {
	local dir="$root/build/mesa/$1"
	local target
	target="$(find "$dir/src/gallium/targets/osmesa" -name target.c.o | head -1)"
	[ -n "$target" ] || { echo "link-core: no Mesa in $dir (run setup-mesa.sh)" >&2; exit 1; }
	echo "$target"
	find "$dir" -name '*.a' | sort
}

case "$flavour" in
	native)
		out="$root/build/native"
		mkdir -p "$out"
		[ -f "$root/build/native-libm/libchimera-m.a" ] || bash "$here/make-native-libm.sh" "$minibox"
		gcc -O2 -g -c -o "$out/run-native.o" "$here/run-native.c" -I"$here"
		gcc -O2 -c -o "$out/jit-symbols.o" "$here/jit-symbols.c"
		# shellcheck disable=SC2046
		g++ -no-pie -o "$out/run-native" "$out/run-native.o" "$out/jit-symbols.o" \
			-Wl,--start-group $(ikemen_libs native) $(mesa_parts build-native) $(llvm_libs native) \
			"$root/build/native-libm/libchimera-m.a" -Wl,--end-group \
			$(cat "$root/build/native-libm/wrap-flags") \
			-Wl,--wrap=dlopen -Wl,--wrap=dlsym -Wl,--wrap=dlclose \
			-lpthread -ldl -lm
		echo "link-core: $out/run-native"
		;;
	guest)
		out="$root/build/guest"
		mkdir -p "$out"
		mb_cpp="$minibox/build/meson-cpp"
		sr="$mb_cpp/guest-sysroot"
		gcc -specs "$sr/lib/musl-gcc.specs" -O2 -mcmodel=large -mno-red-zone -mstack-protector-guard=global \
			-fno-stack-protector -fno-pic -fno-pie -fcf-protection=none -c -o "$out/jit-symbols.o" "$here/jit-symbols.c"
		# shellcheck disable=SC2046
		g++ -specs "$sr/lib/musl-gcc.specs" -static -no-pie \
			-Wl,--eh-frame-hdr -Wl,-O2 -Wl,--no-relax -Wl,--strip-debug -Wl,-z,stack-size=8388608 \
			-T "$minibox/source/guest/linkscript.T" \
			-Wl,-u,pthread_mutexattr_init -Wl,-u,pthread_mutexattr_settype -Wl,-u,pthread_mutexattr_destroy \
			-Wl,-u,pthread_once -Wl,-u,pthread_cond_wait -Wl,-u,pthread_cond_broadcast -Wl,-u,pthread_key_create \
			-o "$out/core.wbx.tmp" \
			-Wl,--start-group $(ikemen_libs guest) $(mesa_parts build-guest2) $(llvm_libs guest) -Wl,--end-group \
			"$mb_cpp/source/guest/cxxglue.c.o" "$mb_cpp/source/guest/emulibc.c.o" "$out/jit-symbols.o" \
			-Wl,--wrap=dlopen -Wl,--wrap=dlsym -Wl,--wrap=dlclose \
			-L"$sr/lib" -lstdc++ -lm -lgcc -lgcc_eh -lc
		sh "$minibox/source/guest/check-wbx.sh" "$out/core.wbx.tmp"
		mv "$out/core.wbx.tmp" "$out/core.wbx"
		# the sandbox runner, against miniBox's host library
		mbhost="$minibox/build/meson-linux/source/host"
		gcc -O2 -g -Wall -o "$out/run-wbx" "$here/run-wbx.c" -I"$here" -I"$minibox/source/host" \
			"$mbhost/libminiboxhost.so" -Wl,-rpath,"$mbhost"
		echo "link-core: $out/core.wbx ($(du -h "$out/core.wbx" | cut -f1)), $out/run-wbx"
		;;
	*)
		echo "usage: $0 native|guest -m <miniBox checkout>" >&2
		exit 2
		;;
esac
