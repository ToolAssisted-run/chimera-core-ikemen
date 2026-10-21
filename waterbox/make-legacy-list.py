#!/usr/bin/env python3
"""Writes the lists the core uses to recognize a game made for an Ikemen GO
older than the one it builds (go/chimera/chimera_legacy.go):

  go/chimera/chimera_legacy_files.txt   "<sha1> <path>" for every version
      the engine's own scripts, shaders and common files had before v1.0.0,
      with carriage returns removed before hashing (games ship them with
      Windows line ends), and without the versions v1.0.0 itself has;
  go/chimera/chimera_legacy_config.json v0.99.0's default settings, which a
      game's save/config.json was written over.

Run it when the pinned Ikemen GO changes, and commit what it writes. It reads
the history of extern/Ikemen-GO, so that checkout needs it (git fetch --tags).

usage: waterbox/make-legacy-list.py"""
import hashlib
import os
import re
import subprocess
import sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
repo = os.path.join(root, "extern", "Ikemen-GO")
out = os.path.join(root, "go", "chimera")
current = "v1.0.0"

# the engine's files that a game folder carries a copy of: what Ikemen GO's
# releases put beside the program, not the content (the screenpack, the
# characters)
engine = re.compile(r"^(external/script/[^/]+|external/shaders/[^/]+\.(vert|frag|spv)|"
                    r"data/[^/]+\.zss|data/common\.(air|cmd|const)|data/common1\.cns)$")


def git(*args, data=None):
    return subprocess.run(["git", "-C", repo] + list(args), input=data, capture_output=True, check=True).stdout


def digest(b):
    return hashlib.sha1(b.replace(b"\r", b"")).hexdigest()


# every version of those files in the history up to the current release
blobs = set()
for line in git("log", "--raw", "--no-abbrev", "--format=", current, "--", "external", "data").decode().splitlines():
    meta, _, name = line.partition("\t")
    fields = meta.split()
    if len(fields) < 5 or not engine.match(name) or fields[3] == "0" * 40:
        continue
    blobs.add((fields[3], name))

# the current release's own versions are not older ones
now = set()
for line in git("ls-tree", "-r", current, "--", "external", "data").decode().splitlines():
    meta, _, name = line.partition("\t")
    if engine.match(name):
        now.add(digest(git("cat-file", "blob", meta.split()[2])))

rows = set()
for blob, name in sorted(blobs):
    h = digest(git("cat-file", "blob", blob))
    if h not in now:
        rows.add("%s %s" % (h, name.lower()))
if not rows:
    sys.exit("make-legacy-list: no history found in %s (git fetch --tags?)" % repo)
with open(os.path.join(out, "chimera_legacy_files.txt"), "w") as f:
    f.write("".join(r + "\n" for r in sorted(rows)))

with open(os.path.join(out, "chimera_legacy_config.json"), "wb") as f:
    f.write(git("show", "v0.99.0:src/resources/defaultConfig.json"))
print("make-legacy-list: %d older versions of %d files" % (len(rows), len({r.split()[1] for r in rows})))
