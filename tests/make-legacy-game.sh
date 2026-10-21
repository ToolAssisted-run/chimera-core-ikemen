#!/usr/bin/env bash
# Makes the older-game test: the screenpack test game (tests/make-test-game.sh)
# as a game made for Ikemen GO v0.99.0 would be, all of it free:
#   - v0.99.0's own scripts and common files (external/script, data/*.zss,
#     data/common.*), with Windows line ends, as games ship them;
#   - two of Ikemen GO's modules as they were in 2023 (Boss Rush, which has a
#     current version, and Rank, which Ikemen GO has since removed);
#   - a v0.99 save/config.json: the screenpack's motif, a round time of 45 and
#     life at 80%, and no game size, so v0.99's 640x480 holds (v1.0's is
#     1280x720).
# With "broken" as a second argument, main.lua has one more line, so it is no
# version the core knows (the test that the core goes by the files' content).
#
# Needs the test game, and fetches the two commits it takes files from when
# the submodules' checkouts do not have them (a shallow checkout).
# usage: tests/make-legacy-game.sh [out.zip] [broken]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${1:-$root/build/tests/legacy-game.zip}"
broken="${2:-}"
base="$root/build/tests/test-game.zip"
[ -f "$base" ] || bash "$here/make-test-game.sh" "$base" > /dev/null
ikemen="$root/extern/Ikemen-GO"
mods="$root/extern/Ikemen-GO-modules"
v099=cb4143e5c968135e42a0641d60b5d1ecb47258e9    # Ikemen GO v0.99.0
mods2023=1bcbf831ad6279291587c0e34e1d4ef7e4b46ec2 # the modules, April 2023
git -C "$ikemen" cat-file -e "$v099^{commit}" 2> /dev/null || git -C "$ikemen" fetch -q --depth 1 origin "$v099"
git -C "$mods" cat-file -e "$mods2023^{commit}" 2> /dev/null || git -C "$mods" fetch -q --depth 1 origin "$mods2023"

work="$(dirname "$out")/legacy-game"
rm -rf "$work"
mkdir -p "$work"
git -C "$ikemen" archive "$v099" external/script data | tar -x -C "$work"
# only the engine's files of data/: the screenpack has the rest
find "$work/data" -type f ! -name '*.zss' ! -name 'common.*' -delete
git -C "$mods" archive "$mods2023" external/mods/bossrush.lua external/mods/rank | tar -x -C "$work"
find "$work/external" "$work/data" -type f \( -name '*.lua' -o -name '*.zss' -o -name '*.def' -o -name 'common.*' \) \
	-exec sed -i 's/$/\r/' {} +
if [ "$broken" = broken ]; then
	printf -- '-- changed\r\n' >> "$work/external/script/main.lua"
fi
mkdir -p "$work/save"
cat > "$work/save/config.json" <<'JSON'
{
  "Motif": "data/ikemen1/system.def",
  "RoundTime": 45,
  "LifeMul": 80,
  "FirstRun": false
}
JSON

rm -f "$out"
python3 - "$base" "$work" "$out" <<'PY'
import os, sys, zipfile
base, work, out = sys.argv[1:]
files = {}
with zipfile.ZipFile(base) as z:
    for n in z.namelist():
        files[n] = z.read(n)
for d, _, fs in os.walk(work):
    for f in fs:
        p = os.path.join(d, f)
        files[os.path.relpath(p, work).replace(os.sep, "/")] = open(p, "rb").read()
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for n in sorted(files):
        info = zipfile.ZipInfo(n, date_time=(2000, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, files[n])
PY
echo "make-legacy-game: $out ($(du -h "$out" | cut -f1))"
