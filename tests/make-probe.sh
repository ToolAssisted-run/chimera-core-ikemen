#!/usr/bin/env bash
# Zips tests/probe (probe.lua and the save/config.ini that makes Ikemen GO run
# it in place of its menus) as a game: the core adds the engine's own files.
# usage: tests/make-probe.sh [out.zip]   (default build/tests/probe.zip)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${1:-$root/build/tests/probe.zip}"
mkdir -p "$(dirname "$out")"
cd "$here/probe"
python3 - "$out" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for n in ["probe.lua", "save/config.ini"]:
        info = zipfile.ZipInfo(n, date_time=(2000, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, open(n, "rb").read())
PY
