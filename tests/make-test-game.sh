#!/usr/bin/env bash
# Makes the test game: the pinned Ikemen GO screenpack (extern/Ikemen-GO-
# Screenpack, the default motif Ikemen GO's releases carry, with Kung Fu Man
# and the training stages) zipped as an Ikemen GO game folder, without the
# artists' work files. The core adds the engine's own data/, external/ and
# font/. Nothing of it is committed here: the screenpack is a submodule, and
# Elecbyte's part of it (Kung Fu Man, two stages, the MUGEN fonts) is under
# Elecbyte's own non-commercial terms (its LICENCE.txt).
#
# usage: tests/make-test-game.sh [out.zip]   (default build/tests/test-game.zip)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${1:-$root/build/tests/test-game.zip}"
sp="$root/extern/Ikemen-GO-Screenpack"
[ -d "$sp/data" ] || { echo "make-test-game: the screenpack submodule is not checked out" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
rm -f "$out"
# a fixed order and fixed times, so that the zip is the same file every time
cd "$sp"
git ls-files -z chars stages data font sound video | python3 -c '
import sys, zipfile
names = sorted(n for n in sys.stdin.read().split("\0") if n and "/work/" not in n)
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for n in names:
        info = zipfile.ZipInfo(n, date_time=(2000, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, open(n, "rb").read())
print(len(names))
' "$out" > /dev/null
echo "make-test-game: $out ($(du -h "$out" | cut -f1))"
