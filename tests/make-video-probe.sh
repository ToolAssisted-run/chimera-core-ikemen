#!/usr/bin/env bash
# Zips tests/video (video.lua, video.def, beeps.webm and the save/config.ini
# that makes Ikemen GO run video.lua in place of its menus) with the
# screenpack's logo video (extern/Ikemen-GO-Screenpack/video) as a game: the
# core adds the engine's own files.
# usage: tests/make-video-probe.sh [out.zip]   (default build/tests/video-probe.zip)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${1:-$root/build/tests/video-probe.zip}"
videos="$root/extern/Ikemen-GO-Screenpack/video"
[ -f "$videos/ik_logo.webm" ] || { echo "make-video-probe: the screenpack submodule is not checked out" >&2; exit 1; }
mkdir -p "$(dirname "$out")"
python3 - "$out" "$here/video" "$videos" <<'PY'
import sys, zipfile
out, src, videos = sys.argv[1:]
files = [(n, src + "/" + n) for n in ["video.lua", "video.def", "save/config.ini"]]
files += [("video/beeps.webm", src + "/beeps.webm"), ("video/ik_logo.webm", videos + "/ik_logo.webm")]
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for n, path in files:
        info = zipfile.ZipInfo(n, date_time=(2000, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        info.external_attr = 0o644 << 16
        z.writestr(info, open(path, "rb").read())
PY
echo "make-video-probe: $out"
