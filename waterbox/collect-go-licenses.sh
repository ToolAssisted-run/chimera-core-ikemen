#!/usr/bin/env bash
# Writes build/licenses/go-modules.txt: the licence text of every Go module
# compiled into the core (go list -deps of Ikemen GO with the core's tags),
# each under its name and version. The modules this repository puts in place
# of others (go/sdl2, go/reisen) are its own and not listed. Run after
# build-ikemen.sh guest, from which it takes the source and the toolchain.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
src="$root/build/ikemen-src"
[ -f "$src/go.mod" ] || { echo "collect-go-licenses: run build-ikemen.sh first" >&2; exit 1; }
export GOROOT="$root/build/go-guest" PATH="$root/build/go-guest/bin:$PATH" GOTOOLCHAIN=local GOFLAGS=-mod=mod
export GOPATH="${CHIMERA_GOPATH:-$root/build/gopath}" GOCACHE="$root/build/gocache-guest" GOEXPERIMENT=arenas CGO_ENABLED=1
out="$root/build/licenses/go-modules.txt"
mkdir -p "$(dirname "$out")"
cd "$src"
{
	echo "The Go modules compiled into the Ikemen GO core, each with its licence."
	echo "(golang/freetype is offered under the FreeType License or the GPL; the"
	echo "core takes the FreeType License: portions of this software are copyright"
	echo "The FreeType Project, www.freetype.org.)"
	go list -deps -tags chimera,kinc,netgo,osusergo -f '{{if .Module}}{{.Module.Path}} {{.Module.Version}}{{end}}' ./src | sort -u |
	while read -r path version; do
		case "$path" in
			github.com/ikemen-engine/Ikemen-GO | github.com/veandco/go-sdl2 | github.com/ikemen-engine/reisen) continue ;;
		esac
		dir="$(go list -m -f '{{.Dir}}' "$path")"
		files="$(find "$dir" -maxdepth 1 -type f \( -iname 'LICEN[CS]E*' -o -iname 'COPYING*' -o -iname 'UNLICENSE*' \) | sort)"
		[ -n "$files" ] || { echo "collect-go-licenses: $path $version has no licence file" >&2; exit 1; }
		echo
		echo "================================================================"
		echo "$path $version"
		echo "================================================================"
		for f in $files; do
			cat "$f"
			echo
		done
	done
} > "$out"
echo "collect-go-licenses: $(grep -c '^====' "$out" | awk '{print $1/2}') modules -> $out"
