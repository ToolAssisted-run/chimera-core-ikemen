#!/usr/bin/env python3
"""Writes a .chimeraProject for an Ikemen GO game, the way the New Project window
would: the game in its slot, the settings, and an input log in the
core's own control names. Also writes the input log alone, for chimera-run.

usage: make-project.py <package> <out.chimeraProject> <frames>
                       [<setting>=<value> ...]
                       [press=<control>:<first>:<count> ...]
                       [axis=<axis>:<first>:<value> ...]
                       [log=<out.txt>]
                       -- <slot>=<file> [<slot>=<file> ...]

A press holds a control for <count> frames from frame <first> (0-based). An
axis takes <value> from frame <first> on (until another axis= for it), as
a mouse stays where it was put; before that it is at its neutral value. A
setting's value is written as JSON would have it.
"""
import hashlib
import json
import os
import sys
import zipfile


def sha1(path):
    h = hashlib.sha1()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 24), b""):
            h.update(chunk)
    return h.hexdigest().upper()


def player_of(name):
    return int(name[1]) if len(name) > 2 and name[0] == "P" and name[1].isdigit() else 0


def main():
    package, out, frames = sys.argv[1], sys.argv[2], int(sys.argv[3])
    rest = sys.argv[4:]
    sep = rest.index("--")
    options, slotargs = rest[:sep], rest[sep + 1:]

    cfg = json.loads(zipfile.ZipFile(package).read("waterbox.config"))
    buttons = cfg["input"]["buttons"]
    axes = cfg["input"].get("axes", [])

    presses, moves, overrides, log_out = {}, {}, [], None
    for o in options:
        k, v = o.split("=", 1)
        if k == "press":
            control, first, count = v.rsplit(":", 2)
            if control not in buttons:
                sys.exit(f"no control is called {control}")
            presses.setdefault(control, []).append((int(first), int(count)))
        elif k == "axis":
            name, first, value = v.rsplit(":", 2)
            if name not in [a["name"] for a in axes]:
                sys.exit(f"no axis is called {name}")
            moves.setdefault(name, []).append((int(first), int(value)))
        elif k == "log":
            log_out = v
        else:
            try:
                overrides.append((k, json.loads(v)))
            except ValueError:
                overrides.append((k, v))

    def axis_at(a, f):
        value = a.get("neutral", 0)
        for first, v in sorted(moves.get(a["name"], [])):
            if first <= f:
                value = v
        return value

    groups = max([player_of(a["name"]) for a in axes] + [player_of(b) for b in buttons] + [0]) + 1
    key = ""
    for g in range(groups):
        key += "#"
        for a in axes:
            if player_of(a["name"]) == g:
                key += a["name"] + "|"
        for b in buttons:
            if player_of(b) == g:
                key += b + "|"
    rows = []
    for f in range(frames):
        row = ""
        for g in range(groups):
            row += "|"
            for a in axes:
                if player_of(a["name"]) == g:
                    row += "%5d," % axis_at(a, f)
            for b in buttons:
                if player_of(b) == g:
                    row += "X" if any(first <= f < first + count for first, count in presses.get(b, [])) else "."
        rows.append(row + "|")
    log = "[Input]\nLogKey:" + key + "\n" + "\n".join(rows) + "\n[/Input]\n"
    if log_out:
        with open(log_out, "w") as f:
            f.write(log)

    files = []
    for arg in slotargs:
        slot, path = arg.split("=", 1)
        files.append({"name": os.path.basename(path), "sha1": sha1(path), "slot": slot})

    settings = {}
    for d in cfg.get("settings", []):
        if d.get("default") is not None:
            settings[d["name"]] = d["default"]
    for k, v in overrides:
        settings[k] = v

    project = {
        "id": "ikemen-test-%s" % os.path.splitext(files[0]["name"])[0],
        "title": "%s through Chimera" % files[0]["name"],
        "description": "written by tests/make-project.py",
        "core": {"name": cfg["coreName"], "version": cfg["version"], "sha1": sha1(package)},
        "rerecords": 0,
        "files": files,
        "settings": settings,
        "firmware": [],
        "coreCache": [],
        "input": log,
        "markers": [],
        "branches": [],
        "headers": {
            "MovieVersion": "Chimera Project File v1.1",
            "Platform": cfg["systemId"],
            "SHA1": files[0]["sha1"] if files else "",
            "LastInputFrame": str(frames - 1),
            "VsyncNumerator": str(cfg["video"]["vsyncNumerator"]),
            "VsyncDenominator": str(cfg["video"]["vsyncDenominator"]),
        },
    }
    with open(out, "w") as f:
        json.dump(project, f, indent="\t")
    return 0


if __name__ == "__main__":
    sys.exit(main())
