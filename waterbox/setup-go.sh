#!/usr/bin/env bash
# Makes the two Go toolchains this core is built with, from one pinned Go
# release:
#
#   build/go-native  Go with the patches both builds share (go-patches/common):
#                    a file system of the program's own (the core's, so both
#                    builds read the game the same way) and one random seed.
#   build/go-guest   the same plus go-patches/guest, which make a Go program
#                    run in the miniBox sandbox: its system calls go to the
#                    sandbox instead of the kernel, a library starts with no
#                    arguments, the tick counter is the sandbox's clock, there
#                    is no asynchronous preemption and no poller, and goroutine
#                    stacks are marked as stacks with room below them for
#                    Windows' fault handling. docs/PLAN.md says why each one.
#
# Only the standard library's source is patched; the compiler and linker are
# the release's own (Go builds the standard library from source on demand).
#
# Usage: ./setup-go.sh            both toolchains (a no-op when they are made)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"

version="1.27.3"
sha256="$(cat "$here/go-patches/go-$version.sha256")"
url="https://go.dev/dl/go$version.linux-amd64.tar.gz"
cache="${CHIMERA_DEPS_DIR:-$root/build/deps}"
tarball="$cache/go$version.linux-amd64.tar.gz"

if [ ! -f "$tarball" ]; then
	mkdir -p "$cache"
	echo "go: fetching $url"
	curl -fL --retry 3 -o "$tarball.part" "$url"
	mv "$tarball.part" "$tarball"
fi
echo "$sha256  $tarball" | sha256sum -c - > /dev/null || {
	echo "go: the tarball is not the release this core is pinned to" >&2
	exit 1
}

make_toolchain() {
	local flavour="$1"
	shift
	local out="$root/build/go-$flavour"
	local stamp="$out/.chimera-patches"
	local want
	want="$(cat "$@" | sha256sum | cut -d' ' -f1)"
	if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$want" ]; then
		echo "go: $flavour toolchain ready in $out"
		return
	fi
	rm -rf "$out"
	mkdir -p "$out"
	tar -xzf "$tarball" -C "$out" --strip-components=1
	local p
	for p in "$@"; do
		patch -d "$out" -p1 --quiet < "$p" || {
			echo "go: $(basename "$p") does not apply to Go $version" >&2
			exit 1
		}
	done
	# a toolchain made with other patches must not share a build cache
	rm -rf "$root/build/gocache-$flavour"
	echo "$want" > "$stamp"
	echo "go: $flavour toolchain made in $out ($# patches)"
}

shopt -s nullglob
common=("$here"/go-patches/common/*.patch)
guest=("$here"/go-patches/guest/*.patch)
make_toolchain native "${common[@]}"
make_toolchain guest "${common[@]}" "${guest[@]}"
