#!/usr/bin/env bash
# Gives the native reference the sandbox's own math functions.
#
# The sandbox build calls musl's sin, pow, expf and the rest; the native
# build would call glibc's, and the two do not agree to the last bit. A last
# bit is enough to move a physics body or a texture's mip level and part the
# two builds, so the native build must compute exactly as the sandbox does.
# It does that with the very objects the sandbox's libm was made of (miniBox's
# guest musl, built as waterbox code: plain x86-64 machine code that runs
# anywhere), renamed so they sit beside glibc without a clash:
#
#   every public function F becomes __wrap_F, so the native link's --wrap=F
#   sends each call to F here (and glibc's own calls stay glibc's);
#   every internal __G becomes chimera_m__G.
#
# Writes build/native-libm/libchimera-m.a and build/native-libm/wrap-flags
# (the linker's --wrap options).
#
# Usage: ./make-native-libm.sh <miniBox checkout>
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
minibox="$(cd "${1:?usage: $0 <miniBox checkout>}" && pwd)"
objs="$minibox/build/meson-cpp/obj/src/math"
[ -d "$objs" ] || {
	echo "make-native-libm: $objs is missing (build miniBox's meson-cpp first)" >&2
	exit 1
}

out="$root/build/native-libm"
rm -rf "$out"
mkdir -p "$out/obj"
# the arch folder's objects replace the generic ones of the same name, as in
# musl's own build; both folders hold only what libc.a got
for o in "$objs"/*.o "$objs"/waterbox/*.o; do
	[ -f "$o" ] || continue
	cp "$o" "$out/obj/$(basename "$o")"
done

nm --defined-only -g "$out"/obj/*.o 2>/dev/null | awk 'NF == 3 { print $3 }' | sort -u > "$out/defined"
: > "$out/rename"
: > "$out/wrap-flags"
while read -r sym; do
	case "$sym" in
		__*) echo "$sym chimera_m$sym" >> "$out/rename" ;;
		*)
			echo "$sym __wrap_$sym" >> "$out/rename"
			printf -- '-Wl,--wrap=%s\n' "$sym" >> "$out/wrap-flags"
			;;
	esac
done < "$out/defined"

for o in "$out"/obj/*.o; do
	objcopy --redefine-syms="$out/rename" "$o"
done
ar rcs "$out/libchimera-m.a" "$out"/obj/*.o

# anything still undefined must be glibc's and not math
undefined="$(nm -u "$out"/obj/*.o 2>/dev/null | awk 'NF == 2 { print $2 }' | sort -u | grep -v '^__wrap_\|^chimera_m' || true)"
echo "make-native-libm: $(wc -l < "$out/wrap-flags") functions; left to the host C library: ${undefined:-nothing}"
