#!/usr/bin/env python3
"""The video checks of waterbox/run-gate.sh, on what the native build wrote:

  <dir>/v<frame>.tga   pictures of the video probe (tests/video) at given frames
  <dir>/n.raw          its sound, 16-bit stereo at 44100 Hz, 735 samples a frame
  <game60.tga>         frame 60 of the screenpack game, during its logo video

Prints one line per check, "ok <name>: ..." or "bad <name>: ...", and exits 1
if any is bad. usage: tests/check-video.py <dir> <game60.tga>"""
import struct
import sys

d, game60 = sys.argv[1], sys.argv[2]


def picture(path):
    data = open(path, "rb").read()
    w, h = struct.unpack_from("<HH", data, 12)
    return w, h, data[0], data[17], data


def pixel(path, x, y):
    w, h, idlen, desc, data = picture(path)
    row = y if desc & 0x20 else h - 1 - y
    o = 18 + idlen + (row * w + x) * 4
    b, g, r = data[o], data[o + 1], data[o + 2]
    return r, g, b


bad = 0


def report(ok, name, what):
    global bad
    print(("ok " if ok else "bad ") + name + ": " + what)
    bad += not ok


# beeps.webm is white from 1.0 to 1.1 s and from 2.0 to 2.1 s: six pictures at
# 60 a second. The storyboard starts it one frame in, so frames 59-64 and
# 119-124. A corner, away from the logo over it.
def white(f):
    return min(pixel("%s/v%d.tga" % (d, f), 8, 8)) > 200


def black(f):
    return max(pixel("%s/v%d.tga" % (d, f), 8, 8)) < 30


want = {58: black, 59: white, 64: white, 65: black, 118: black, 119: white, 124: white, 125: black}
seen = {f: test(f) for f, test in want.items()}
report(all(seen.values()), "pictures",
       "the test video is white on frames 59-64 and 119-124 and black either side"
       + ("" if all(seen.values()) else " (wrong on frames %s)" % [f for f, ok in seen.items() if not ok]))

# its beeps: heard from the frames the white pictures start on
raw = open(d + "/n.raw", "rb").read()
samples = struct.unpack("<%dh" % (len(raw) // 2), raw)
per = 735 * 2
loud = [f for f in range(len(samples) // per) if max(abs(s) for s in samples[f * per:(f + 1) * per]) > 1000]
starts = [f for f in loud if f - 1 not in loud]
report(starts == [59, 119], "sound",
       "the test video's beeps start on frames %s (the white pictures' 59 and 119)" % starts)

# the logo loops: 4 seconds, 240 frames, so frame 260 is frame 20 again
same = open("%s/v20.tga" % d, "rb").read() == open("%s/v260.tga" % d, "rb").read()
report(same, "loop", "the looping logo video shows frame 20's picture again at frame 260, 240 frames (4 s) on"
       if same else "frame 260 of the looping logo video is not frame 20's picture")

# the screenpack game opens on its logo video: without the video, black
w, h, idlen, desc, data = picture(game60)
lit = sum(1 for i in range(18 + idlen, 18 + idlen + w * h * 4, 4) if max(data[i:i + 3]) > 64)
report(lit > w * h // 50, "logo",
       "frame 60 of the screenpack game shows its logo video (%d of %d pixels lit)" % (lit, w * h))

sys.exit(1 if bad else 0)
