#!/usr/bin/env bash
# Makes the media test game: a zip of music files and an SND file for the
# media check (tests/media), made here with the computer's ffmpeg from
# generated sound, so nothing of anyone's is in it:
#   sound/song.ogg, song.mp3, song.flac   a sweep, a beat and noise, 6 s
#   sound/mono8.wav                       the same, 8-bit mono at 11025 Hz
#   sound/junk-end.mp3                    song.mp3 with a kilobyte of junk and
#                                         an ID3v1 tag after its last frame (the
#                                         junk holds bytes that look like frame
#                                         headers the decoder cannot decode)
#   sound/song.mpc                        Musepack, if mpcenc is installed
#   chars/media/media.snd                 sounds of 16-bit stereo 44100 Hz, 8-bit
#                                         mono 22050 Hz, 16-bit mono 11025 Hz,
#                                         and a 110-byte one Ikemen GO leaves out
#
# usage: tests/make-media-game.sh [out.zip]   (default build/tests/media-game.zip)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${1:-$root/build/tests/media-game.zip}"
command -v ffmpeg > /dev/null || { echo "make-media-game: needs ffmpeg" >&2; exit 1; }
work="$(dirname "$out")/media-game"
rm -rf "$work"
mkdir -p "$work/sound" "$work/chars/media" "$(dirname "$out")"

# a sweep, a beat that comes and goes, and bursts of noise: a loudness that
# changes, for the envelopes to follow
src=(-f lavfi -i "aevalsrc=exprs='0.4*sin(2*PI*(200+300*t)*t)*(0.5+0.5*sin(2*PI*2*t))|0.3*sin(2*PI*330*t)*lt(t,3)+0.3*sin(2*PI*660*t)*gte(t,3)':s=44100:d=6"
	-f lavfi -i "anoisesrc=d=6:c=pink:r=44100:a=0.15:seed=7")
mix=(-filter_complex "[1]volume='if(lt(mod(t,1),0.2),1,0)':eval=frame,aformat=channel_layouts=stereo[n];[0][n]amix=inputs=2:normalize=0")
ff() { ffmpeg -v error -y "${src[@]}" "${mix[@]}" "$@"; }
ff -c:a libvorbis -q:a 5 "$work/sound/song.ogg"
ff -c:a libmp3lame -b:a 160k "$work/sound/song.mp3"
ff -c:a flac "$work/sound/song.flac"
ff -ac 1 -ar 11025 -c:a pcm_u8 "$work/sound/mono8.wav"
python3 - "$work/sound/song.mp3" "$work/sound/junk-end.mp3" <<'PY'
import sys
song = open(sys.argv[1], "rb").read()
# junk after the last frame: zeros, words that look like a free bitrate
# header (ff ff 07 00) and a layer 2 one (ff fd 90 00), more zeros, then a tag
junk = bytes(400) + b"\xff\xff\x07\x00" + bytes(200) + b"\xff\xfd\x90\x00" + bytes(300)
tag = b"TAG" + b"junk at the end".ljust(30, b"\0") + bytes(30 + 30 + 4 + 30) + b"\xff"
open(sys.argv[2], "wb").write(song + junk + tag)
PY
if command -v mpcenc > /dev/null; then
	ff -c:a pcm_s16le "$work/song.wav"
	mpcenc --silent --quality 5 "$work/song.wav" "$work/sound/song.mpc"
	rm "$work/song.wav"
else
	echo "make-media-game: mpcenc is not installed, so there is no Musepack file"
fi

# the SND file: Elecbyte's header, then one subheader and WAV per sound
for spec in "s16le 2 44100 a" "u8 1 22050 b" "s16le 1 11025 c"; do
	set -- $spec
	ff -ac "$2" -ar "$3" -t 1.5 -c:a "pcm_$1" "$work/$4.wav"
done
python3 - "$work" "$work/chars/media/media.snd" <<'PY'
import struct, sys
work, out = sys.argv[1], sys.argv[2]
sounds = [((0, 0), open(work + "/a.wav", "rb").read()), ((0, 1), open(work + "/b.wav", "rb").read()),
          ((1, 0), open(work + "/c.wav", "rb").read())]
# a 110-byte placeholder: a valid WAV of 65 samples, 8-bit mono 22050 Hz
pcm = bytes((128 + (i * 37 % 41) - 20) & 0xff for i in range(65)) + b"\0"
sounds.append(((2, 0), b"RIFF" + struct.pack("<I", 102) + b"WAVEfmt " + struct.pack("<IHHIIHH", 16, 1, 1, 22050, 22050, 1, 8)
               + b"data" + struct.pack("<I", 65) + pcm))
assert len(sounds[-1][1]) == 110
body, off = b"", 32
for i, ((g, n), wav) in enumerate(sounds):
    nxt = off + 16 + len(wav) if i + 1 < len(sounds) else 0
    body += struct.pack("<IIii", nxt, len(wav), g, n) + wav
    off += 16 + len(wav)
head = b"ElecbyteSnd\0" + struct.pack("<HHII", 0, 1, len(sounds), 32) + bytes(8)
open(out, "wb").write(head + body)
PY
rm -f "$work"/[abc].wav

rm -f "$out"
(cd "$work" && python3 -c '
import os, sys, zipfile
names = sorted(os.path.join(d, f)[2:] for d, _, fs in os.walk(".") for f in fs)
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for n in names:
        info = zipfile.ZipInfo(n, date_time=(2000, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        z.writestr(info, open(n, "rb").read())
' "$out")
echo "make-media-game: $out ($(du -h "$out" | cut -f1))"
