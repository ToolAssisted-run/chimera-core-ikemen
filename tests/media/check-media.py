#!/usr/bin/env python3
"""Checks what the media check (tests/media/chimera_media.go) printed:

  - every music file and every sound came out of the engine's playback to
    its end, without an error (an empty file, which holds no sound, is
    noted), and no sound of an SND file was left out by the engine's reader
    because it could not be played to its end. Ikemen GO also leaves out
    every sound under 128 bytes; those are noted, and kept out (the owner's
    decision, 2026-10-21: as Ikemen GO v0.99 and v1.0 do);
  - what came out matches ffmpeg's decoding of the same file, resampled to
    44100 Hz: as long (within a few frames: MP3 decoders differ on the
    encoder's padding), and as loud frame by frame (the loudness of every
    735 frames, the envelope, correlates, and the whole is as loud). The two
    decoders and resamplers differ in their last bits, so the sound itself is
    not compared bit for bit. What does not agree is looked at again with
    ffmpeg's decoding resampled the engine's way (beep's resampler at the
    quality the check printed: 1, Ikemen GO's default, draws a straight line
    between two samples, which dulls the top of a sound recorded at a low
    rate), so that only a difference of the decoding counts;
  - given a second output (the sandbox's), every result is the same, bit for
    bit (the sha1 of the 16-bit sound).

usage: check-media.py <game zip> <core output> [<sandbox output>]
Prints a line per problem and a summary; exits 1 if there is a problem."""
import concurrent.futures
import math
import os
import struct
import subprocess
import sys
import tempfile
import zipfile

zpath, outs = sys.argv[1], sys.argv[2:]


def parse(path):
    items, last = {}, None
    for line in open(path, encoding="utf-8", errors="surrogateescape"):
        f = line.rstrip("\n").split("\t")
        if f[0] == "music" and len(f) >= 3:
            last = ("music", f[1], "")
            items[last] = {"status": f[2], **dict(x.split("=", 1) for x in f[3:])}
        elif f[0] == "sound" and len(f) >= 4:
            last = ("sound", f[1], f[2])
            items[last] = {"status": f[3], **dict(x.split("=", 1) for x in f[4:])}
        elif f[0] == "env" and last:
            items[last]["env"] = [int(x) for x in f[1].split(",") if x]
    return items


core = parse(outs[0])
problems = []

if len(outs) > 1:
    box = parse(outs[1])
    for k in sorted(set(core) | set(box)):
        a, b = core.get(k), box.get(k)
        if a is None or b is None:
            problems.append("%s %s %s: only in %s" % (k[0], k[1], k[2], "the sandbox" if a is None else "native"))
        elif (a["status"], a.get("frames"), a.get("sha1")) != (b["status"], b.get("frames"), b.get("sha1")):
            problems.append("%s %s %s: native %s %s frames, sandbox %s %s frames" % (
                k[0], k[1], k[2], a["status"], a.get("frames"), b["status"], b.get("frames")))

z = zipfile.ZipFile(zpath)
names = {n.lower(): n for n in z.namelist()}


def game_bytes(p):
    n = names.get(p.lower())
    return z.read(n) if n is not None else None


def snd_entries(data):
    out = {}
    if data[:12] != b"ElecbyteSnd\0":
        return out
    count, off = struct.unpack_from("<II", data, 16)
    for _ in range(count):
        if off + 16 > len(data):
            break
        nxt, ln, g, n = struct.unpack_from("<IIii", data, off)
        out.setdefault("%d,%d" % (g, n), data[off + 16:off + 16 + ln])  # the first of a number, as the engine
        off = nxt
    return out


def ffmpeg(args, data):
    """ffmpeg (or ffprobe) on the file's bytes, from a file of its own: some
    formats (Musepack 8) cannot be read from a pipe, which cannot seek."""
    with tempfile.NamedTemporaryFile(suffix=".media") as f:
        f.write(data)
        f.flush()
        return subprocess.run([a if a != "pipe:0" else f.name for a in args], capture_output=True)


def envelope(data):
    """ffmpeg's decoding at 44100 Hz, the RMS of every 735 frames over the
    file's own channels (the engine plays mono at full level on both sides,
    which has the same RMS; ffmpeg's own turning of mono into stereo would
    lower it 3 dB)."""
    r = ffmpeg(["ffmpeg", "-v", "error", "-i", "pipe:0", "-af",
                "aresample=44100,aformat=sample_fmts=s16,"
                "asetnsamples=n=735:p=0,astats=metadata=1:reset=1,"
                "ametadata=print:key=lavfi.astats.Overall.RMS_level:file=-",
                "-f", "null", "-"], data)
    env = []
    for line in r.stdout.decode().splitlines():
        if line.startswith("lavfi.astats.Overall.RMS_level="):
            v = line.split("=", 1)[1]
            env.append(0 if v in ("-inf", "inf", "nan") else 32767 * 10 ** (float(v) / 20))
    return env, r.stderr.decode().strip()


def as_engine(data, quality):
    """ffmpeg's decoding at the file's own rate, resampled to 44100 Hz as
    beep.Resample does at quality 1 (a line between the two samples around
    each position), and its envelope; None at other qualities."""
    if quality != 1:
        return None
    probe = ffmpeg(["ffprobe", "-v", "error", "-show_entries", "stream=sample_rate,channels", "-of",
                    "default=nw=1", "pipe:0"], data).stdout.decode()
    info = dict(l.split("=", 1) for l in probe.splitlines() if "=" in l)
    rate, ch = int(info.get("sample_rate", 0)), int(info.get("channels", 0))
    if not rate or not ch:
        return None
    raw = ffmpeg(["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "s16le", "-"], data).stdout
    n = len(raw) // (2 * ch)
    pcm = struct.unpack("<%dh" % (n * ch), raw[:n * ch * 2])
    ratio = rate / 44100
    env, acc, k, i = [], 0.0, 0, 0
    while True:
        x = i * ratio
        x0 = int(x)
        if x0 >= n:
            break
        t = x - x0
        for c in range(ch):
            y0 = pcm[x0 * ch + c]
            y = y0 + (pcm[(x0 + 1) * ch + c] - y0) * t if x0 + 1 < n else y0
            acc += y * y
        k += 1
        i += 1
        if k == 735:
            env.append(math.sqrt(acc / (735 * ch)))
            acc, k = 0.0, 0
    if k:
        env.append(math.sqrt(acc / (k * ch)))
    return env


def correlation(x, y):
    m = min(len(x), len(y))
    x, y = x[:m], y[:m]
    if m < 3:
        return 1.0
    mx, my = sum(x) / m, sum(y) / m
    sxy = sum((p - mx) * (q - my) for p, q in zip(x, y))
    sxx = sum((p - mx) ** 2 for p in x)
    syy = sum((q - my) ** 2 for q in y)
    return sxy / math.sqrt(sxx * syy) if sxx > 0 and syy > 0 else 1.0


def blocks(e, n=5):
    return [math.sqrt(sum(v * v for v in e[i:i + n]) / len(e[i:i + n])) for i in range(0, len(e), n)]


def compare(a, b, lenient):
    """None if the envelopes a (the core) and b (ffmpeg) agree, else why not.
    Over a long sound, the loudness of every 5 frames is what correlates: the
    decoders' start can differ by a part of a frame."""
    if abs(len(a) - len(b)) > (8 if lenient else 3):
        return "%d frames long, ffmpeg's %d" % (len(a), len(b))
    if max(b, default=0) < 40:
        return None if max(a, default=0) < 80 else "sound where ffmpeg has silence"
    best = None
    for lag in range(-6, 7):
        x = a[max(0, lag):]
        y = b[max(0, -lag):]
        corr = correlation(blocks(x), blocks(y)) if len(a) >= 50 else correlation(x, y)
        if best is None or corr > best[0]:
            best = (corr, lag)
    ea = math.sqrt(sum(v * v for v in a) / max(1, len(a)))
    eb = math.sqrt(sum(v * v for v in b) / max(1, len(b)))
    ratio = ea / eb if eb else 0
    if not 0.8 <= ratio <= 1.25:
        return "loudness %.2f of ffmpeg's" % ratio
    if len(a) >= 20 and best and best[0] < 0.97:
        return "loudness over time correlates %.3f with ffmpeg's" % best[0]
    return None


quality = 1
for line in open(outs[0], encoding="utf-8", errors="surrogateescape"):
    if line.startswith("media check: resampling quality "):
        quality = int(line.split()[-1])
notes = []
jobs = {}
sndcache = {}
for k, it in core.items():
    kind, p, gn = k
    if it["status"] != "ok":
        if kind == "music" and game_bytes(p) == b"":
            notes.append("music %s: an empty file, which holds no sound" % p)
        else:
            problems.append("%s %s %s: %s" % (kind, p, gn, it["status"]))
        continue
    if kind == "music":
        data = game_bytes(p)
    else:
        if p not in sndcache:
            raw = game_bytes(p)
            sndcache[p] = snd_entries(raw) if raw is not None else None
        data = sndcache[p].get(gn) if sndcache[p] is not None else None
    if data is None:
        continue  # an engine file, not the game's
    jobs[k] = (data, p.lower().endswith(".mp3"))

# the sounds of every SND file the engine read that did not come out of it
small = {}
for p in sorted({k[1] for k in core if k[0] == "sound"}):
    raw = game_bytes(p)
    if raw is None:
        continue
    out = {k[2] for k in core if k[0] == "sound" and k[1] == p}
    for gn, data in snd_entries(raw).items():
        g, n = (int(x) for x in gn.split(","))
        if g >= 0 and n >= 0 and gn not in out:
            if len(data) < 128:
                small[len(data)] = small.get(len(data), 0) + 1
            else:
                problems.append("sound %s %s: the engine leaves it out (%d bytes)" % (p, gn, len(data)))

if small:
    notes.append("%d sounds under 128 bytes are left out, as Ikemen GO leaves them out (sizes: %s)" % (
        sum(small.values()), ", ".join("%d bytes x%d" % kv for kv in sorted(small.items()))))

checked = 0
resampled = []
with concurrent.futures.ThreadPoolExecutor(max_workers=os.cpu_count()) as pool:
    futs = {pool.submit(envelope, data): (k, lenient) for k, (data, lenient) in jobs.items()}
    for fut in concurrent.futures.as_completed(futs):
        k, lenient = futs[fut]
        env, err = fut.result()
        if not env:
            problems.append("%s %s %s: ffmpeg could not decode it either (%s)" % (k[0], k[1], k[2], err[:120]))
            continue
        why = compare(core[k].get("env", []), env, lenient)
        checked += 1
        if why:
            again = as_engine(jobs[k][0], quality)
            if again is not None and compare(core[k].get("env", []), again, lenient) is None:
                resampled.append(k)
            else:
                problems.append("%s %s %s: %s" % (k[0], k[1], k[2], why))

music = sum(1 for k in core if k[0] == "music")
sounds = sum(1 for k in core if k[0] == "sound")
for p in sorted(notes):
    print("note: " + p)
for p in sorted(problems):
    print("problem: " + p)
print("media: %d music files and %d sounds; %d compared with ffmpeg (%d of them only once resampled the engine's way); %d problems%s" % (
    music, sounds, checked, len(resampled), len(problems), "; native = sandbox for every one" if len(outs) > 1 and not any(
        "sandbox" in p for p in problems) else ""))
sys.exit(1 if problems else 0)
