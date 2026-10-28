#!/usr/bin/env bash
# Builds the Ikemen GO core package, ikemen.chimeraCore.
#
# A package is core.wbx (fixed name) + waterbox.config + default_keybinds.json +
# file_slots.json + the licences, loaded through chimera's one built-in generic
# adapter. It carries no game: the project brings the game folder as a zip.
#
# Usage: ./build-package.sh [-m <miniBox dir>] [-r <chimera root>] [-o <out dir>]
#   -r installs the package into <chimera root>/build/Cores (what CI's publish
#      job does); -o writes it to <out dir> instead. Neither: build/package.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
mb="${MINIBOX_DIR:-}"
chimera_root=""
out=""
while getopts "m:r:o:" opt; do
	case "$opt" in
		m) mb="$OPTARG" ;;
		r) chimera_root="$OPTARG" ;;
		o) out="$OPTARG" ;;
		*) exit 2 ;;
	esac
done

if [ -n "$chimera_root" ]; then
	[ -d "$chimera_root" ] || { echo "no chimera checkout at $chimera_root" >&2; exit 1; }
	chimera_root="$(cd "$chimera_root" && pwd)"
	[ -n "$mb" ] || mb="$chimera_root/extern/chimera-common-minibox"
	[ -n "$out" ] || out="$chimera_root/build/Cores"
fi
[ -n "$mb" ] && [ -d "$mb" ] || { echo "miniBox not found; pass -m <path>, -r <chimera checkout> or set MINIBOX_DIR" >&2; exit 1; }
mb="$(cd "$mb" && pwd)"
[ -n "$out" ] || out="$root/build/package"

# Go (both toolchains), LLVM and Mesa (the guest's OpenGL, built once into
# build/), libxmp, FFmpeg, Ikemen GO for the guest, then the link (link-core.sh runs
# check-wbx before it calls core.wbx built)
mkdir -p "$root/build"
step() { # step <log> <what> <command...>
	local log="$root/build/package-$1.log" what="$2"
	shift 2
	"$@" > "$log" 2>&1 || { tail -20 "$log" >&2; echo "$what failed (build/package-$(basename "$log" .log | sed 's/^package-//').log)" >&2; exit 1; }
}
step go "the Go toolchains" bash "$here/setup-go.sh"
step llvm "the native LLVM build" bash "$here/build-llvm.sh" native
step llvm-guest "the guest LLVM build" bash "$here/build-llvm.sh" guest -m "$mb"
step mesa "the guest Mesa build" bash "$here/setup-mesa.sh" -m "$mb"
step libxmp "the guest libxmp build" bash "$here/build-libxmp.sh" guest -m "$mb"
step ffmpeg "the guest FFmpeg build" bash "$here/build-ffmpeg.sh" guest -m "$mb"
step ikemen "the guest Ikemen GO build" bash "$here/build-ikemen.sh" guest -m "$mb"
step licenses "collecting the Go modules' licences" bash "$here/collect-go-licenses.sh"
step link "the guest link" bash "$here/link-core.sh" guest -m "$mb"
sh "$mb/source/guest/check-wbx.sh" "$root/build/guest/core.wbx"

staging="$root/build/package-staging"
rm -rf "$staging"
mkdir -p "$staging"
cp "$root/build/guest/core.wbx" "$staging/core.wbx"
cp "$here/waterbox.config" "$staging/waterbox.config"
cp "$here/default_keybinds.json" "$staging/default_keybinds.json"
# The core-declared file form for the project wizard - the frontend renders it,
# this file decides it.
cp "$here/file_slots.json" "$staging/file_slots.json"
# the texts a person reads, a table per language (chimera docs/translations.md)
cp -r "$here/languages" "$staging/languages"
# the terms travel with the binary: Ikemen GO, Go and its modules, libxmp,
# Mesa, LLVM, FFmpeg and libvpx are somebody else's work (see
# waterbox/package-licenses.json)
python3 "$mb/source/guest/package-licenses.py" "$root" "$staging"

# ---- version (see chimera docs: commit-as-version, stamped by CD) ----
core_version="${CORE_VERSION:-}"
if [ -z "$core_version" ]; then
	if commit="$(git -C "$root" rev-parse --short=12 HEAD 2>/dev/null)"; then
		# the build works on a copy of extern/Ikemen-GO, never in it; a submodule's
		# own working tree does not make the package dirty
		git -C "$root" diff --quiet --ignore-submodules=dirty HEAD 2>/dev/null || commit="$commit-dirty"
		core_version="$commit+local"
	else
		core_version="unversioned+local"
	fi
fi
# When that commit was made, beside it (chimera issue #67): the COMMIT's date, in
# UTC, and never the build's - the same commit must still make the same package.
core_version_date="$(TZ=UTC git -C "$root" log -1 --date=format-local:%Y-%m-%dT%H:%M:%SZ --format=%cd HEAD 2>/dev/null || true)"
python3 - "$staging/waterbox.config" "$core_version" "$core_version_date" <<'PYVER'
import json, sys
path, version, date = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    cfg = json.load(f)
cfg["version"] = version
if date:
    cfg["versionDate"] = date
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYVER

# ---- provenance: what built this exact package (inputs only) ----
gccver="$(gcc -dumpfullversion)"
musl_version="$(cat "$mb/extern/musl/VERSION" 2>/dev/null || echo unknown)"
binutils_version="$(ld --version | head -1 | grep -o '[0-9][0-9.]*$' || echo unknown)"
os_id="$(. /etc/os-release 2>/dev/null && printf '%s %s' "${ID:-unknown}" "${VERSION_ID:-}" || echo unknown)"
guest_kit="$(git -C "$mb" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
ikemen_pin="$(git -C "$root/extern/Ikemen-GO" describe --tags --always 2>/dev/null || echo unknown)"
python3 - "$staging/build.json" <<PYPROV
import json, subprocess
def git(*args, default="unknown"):
    try:
        return subprocess.run(["git", "-C", "$root", *args], capture_output=True,
                              text=True, check=True).stdout.strip()
    except Exception:
        return default
json.dump({
    "version": "$core_version",
    "source": {"commit": git("rev-parse", "HEAD"),
               "origin": git("config", "--get", "remote.origin.url", default=""),
               "dirty": "-dirty" in "$core_version"},
    "toolchain": {"compiler": "gcc $gccver", "binutils": "$binutils_version",
                  "target": "x86_64-linux-musl", "musl": "$musl_version"},
    "guestKit": {"name": "miniBox", "commit": "$guest_kit"},
    "upstream": {"name": "Ikemen GO", "pin": "$ikemen_pin"},
    "go": "1.27.3 (waterbox/go-patches)",
    "builtOn": "$os_id",
}, open("$staging/build.json", "w"), indent=2, sort_keys=True)
PYPROV

mkdir -p "$out"
zip_path="$out/ikemen.chimeraCore"
rm -f "$zip_path"
# deterministic packaging: sorted entries, fixed timestamp/permissions, pinned
# compression - the package's SHA1 is the core's identity (movies cite it)
python3 - "$staging" "$zip_path" <<'PYEOF'
import hashlib, os, sys, tempfile, zipfile

staging, zip_path = sys.argv[1], sys.argv[2]
FIXED_DATE = (1980, 1, 1, 0, 0, 0)

def write_package(path):
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for root, dirs, files in os.walk(staging):
            dirs.sort()
            for name in sorted(files):
                full = os.path.join(root, name)
                info = zipfile.ZipInfo(os.path.relpath(full, staging), date_time=FIXED_DATE)
                info.compress_type = zipfile.ZIP_DEFLATED
                info.create_system = 3
                info.external_attr = 0o644 << 16
                with open(full, "rb") as f:
                    z.writestr(info, f.read())

write_package(zip_path)
with tempfile.NamedTemporaryFile(suffix=".zip") as tmp:
    write_package(tmp.name)
    again = hashlib.sha1(open(tmp.name, "rb").read()).hexdigest()
first = hashlib.sha1(open(zip_path, "rb").read()).hexdigest()
if first != again:
    sys.exit(f"packaging is not deterministic: {first} then {again}")
print(f"package sha1 {first}")
PYEOF

if [ -n "$chimera_root" ]; then
	for cache in "$chimera_root"/build/CoreCache/ikemen-*; do
		[ -d "$cache" ] && rm -rf "$cache" || true
	done
fi
echo "packaged -> $zip_path"
