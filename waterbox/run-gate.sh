#!/bin/bash
# run-gate.sh - the Ikemen GO core's tests: the native reference (run-native)
# and the sandbox (core.wbx through run-wbx) are the same machine, on two
# games the scripts make: the Ikemen GO screenpack from the submodule, zipped
# as a game folder (tests/make-test-game.sh), this repository's probe
# (tests/probe: a Lua script Ikemen GO runs in place of its menus, which
# prints every frame what the game learns from the machine), and its video
# probe (tests/video: a storyboard of two videos, one with sound).
#
# Every test says what it compared. The tests:
#   equivalence  the screenpack game from boot (its logo video) through VS
#                Mode, both players picking Kung Fu Man, a random stage, the
#                round's intro and a fight: every frame's picture, the sound,
#                the steps and lag, the clock; the probe's lines and pictures;
#                the video probe's pictures and sound
#   rerecord     the sandbox saved and loaded before every frame = without
#                (the probe, the first 300 frames of the game, the first 130
#                of the video probe)
#   session      saved in the middle of the fight, or of the videos, a new
#                host, loaded and finished = without
#   turbo        the first half not read back: the rest the same, and the
#                first half's pictures really not there
#   teeth        the comparison sees a button pressed one frame later
#   clock        the game's clock starts at the Starting Clock setting and
#                moves 1/60 s a frame; the computer stalling between frames
#                changes nothing
#   random       the engine's random numbers come from the Starting Clock:
#                the same in both builds, other numbers for another date
#   controls     each player's buttons reach the game (triggers and Menu
#                included), and Escape
#   save data    Export Save Data is what the game wrote, the same in both
#                builds and after a session; a project's save file, or the
#                export's zip, is in the game's folder when it starts; a zip
#                that names a place outside it is refused
#   renderer     the game draws on llvmpipe with the pinned CPU's 128-bit
#                vectors in both builds, whatever this computer has
#   videos       a video's pictures and its sound come on the frames their
#                times say, a looping video starts again when it ends, and
#                the game's logo video is drawn
#   older games  the screenpack game made into a game for Ikemen GO v0.99.0
#                (tests/make-legacy-game.sh): the core recognizes v0.99's
#                scripts and gives way to its own, replaces the old Boss Rush
#                module and leaves out Rank, turns save/config.json into
#                config.ini, and the game plays to a fight, native = sandbox;
#                with one line of main.lua changed, it recognizes nothing
#   media        the media check's test build (tests/media) pulls every music
#                file and sound of the media test game (tests/make-media-game.sh:
#                OGG, MP3, FLAC, WAV, an MP3 ending in junk, Musepack when
#                mpcenc is installed, an SND file) and of the screenpack game
#                through the engine's playback: the same in both builds, and
#                as ffmpeg decodes them
#   refusals     no game, and a file that is not a zip: each says why
#   kof special  only with IKEMEN_KOF_ZIP naming a copy of KOF Special (a fan
#                game made for v0.99.0, which may not be shared): its media
#                all play, as ffmpeg decodes them, the same in both builds; it
#                is recognized as an older game; Arcade to the second round,
#                native = sandbox, and saved in the fight = straight.
#                SKIP without it.
#
# usage: run-gate.sh -m <miniBox checkout>    [IKEMEN_KOF_ZIP=<zip>]
set -u
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
mb="${MINIBOX_DIR:-}"
while getopts "m:" opt; do
	case "$opt" in
		m) mb="$OPTARG" ;;
		*) exit 2 ;;
	esac
done
[ -n "$mb" ] && [ -d "$mb" ] || { echo "pass -m <miniBox checkout>" >&2; exit 2; }
mb="$(cd "$mb" && pwd)"

echo "== build (miniBox $mb)"
mkdir -p "$root/build"
step() { # step <what> <log> <command...>
	local what="$1" log="$2"; shift 2
	if ! "$@" > "$log" 2>&1; then
		grep "error" "$log" | head -10; tail -15 "$log"; echo "$what failed ($log)"; exit 1
	fi
}
step "the Go toolchains" "$root/build/gate-go.log" bash "$here/setup-go.sh"
step "the LLVM builds" "$root/build/gate-llvm.log" bash -c "bash '$here/build-llvm.sh' native && bash '$here/build-llvm.sh' guest -m '$mb'"
step "the Mesa builds" "$root/build/gate-mesa.log" bash -c "bash '$here/setup-mesa.sh' -m '$mb' && bash '$here/setup-mesa.sh' -n"
step "the libxmp builds" "$root/build/gate-libxmp.log" bash -c "bash '$here/build-libxmp.sh' native && bash '$here/build-libxmp.sh' guest -m '$mb'"
step "the FFmpeg builds" "$root/build/gate-ffmpeg.log" bash -c "bash '$here/build-ffmpeg.sh' native && bash '$here/build-ffmpeg.sh' guest -m '$mb'"
step "the sandbox's math for the native build" "$root/build/gate-libm.log" bash "$here/make-native-libm.sh" "$mb"
step "the native Ikemen GO build" "$root/build/gate-native.log" bash "$here/build-ikemen.sh" native -m "$mb"
step "the native link" "$root/build/gate-link-native.log" bash "$here/link-core.sh" native -m "$mb"
step "the guest Ikemen GO build" "$root/build/gate-guest.log" bash "$here/build-ikemen.sh" guest -m "$mb"
step "the guest link" "$root/build/gate-link-guest.log" bash "$here/link-core.sh" guest -m "$mb"
step "the media check's test builds" "$root/build/gate-media.log" bash -c "export CHIMERA_VARIANT=media; bash '$here/build-ikemen.sh' native -m '$mb' && bash '$here/link-core.sh' native -m '$mb' && bash '$here/build-ikemen.sh' guest -m '$mb' && bash '$here/link-core.sh' guest -m '$mb'"
step "the test games" "$root/build/gate-games.log" bash -c "bash '$root/tests/make-test-game.sh' && bash '$root/tests/make-probe.sh' && bash '$root/tests/make-video-probe.sh' && bash '$root/tests/make-legacy-game.sh' && bash '$root/tests/make-legacy-game.sh' '$root/build/tests/legacy-broken.zip' broken && bash '$root/tests/make-media-game.sh'"
native="$root/build/native/run-native"
wbx="$root/build/guest/run-wbx"
core="$root/build/guest/core.wbx"

work="$root/build/gate"
rm -rf "$work"
mkdir -p "$work"
passed=0
fails=0
pass() { echo "PASS $*"; passed=$((passed + 1)); }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
skip() { echo "SKIP $*"; skipped=$((skipped + 1)); }
skipped=0

# what a run says: the digests and the probe's lines (Ikemen GO's own start-up
# lines are not the machine's). A session starts the game a second time in
# the new host before the state replaces it, and that start (Init runs to the
# first frame's end) prints the probe's start line and its frame 0 line
# again: only the first of each counts.
digests() { grep -E '^([A-Za-z]+(\[[^]]*\])?=|probe )' "$1" | awk '!/^probe (start|f=0 )/ || !seen[$0]++' || true; }
same() { # same <test> <a> <b> <what>
	digests "$2" > "$2.d"
	digests "$3" > "$3.d"
	# two runs that both stopped at the start are the same, and prove
	# nothing: both must have run to their last frame (the clock line)
	if grep -q '^loadError=' "$2.d" "$3.d" || ! grep -q '^clock=' "$2.d" || ! grep -q '^clock=' "$3.d"; then
		fail "$1: $4 (a run stopped: $(grep -h -m1 '^loadError=' "$2.d" "$3.d" | head -1))"
	elif [ -s "$2.d" ] && cmp -s "$2.d" "$3.d"; then
		pass "$1: $4"
	else
		fail "$1: $4"; diff "$2.d" "$3.d" | head -20
	fi
}
value() { digests "$1" | sed -n "s/^$2=//p"; }
has() { # has <test> <file> <fixed line> <what>
	if grep -qF -- "$3" "$2"; then pass "$1: $4"; else fail "$1: $4 (no line '$3')"; grep '^probe' "$2" | head -5; fi
}
mkwork() { # mkwork <dir> <game zip> [<settings JSON>]
	mkdir -p "$work/$1"
	cp "$2" "$work/$1/"
	printf '{"game":["%s"]}' "$(basename "$2")" > "$work/$1/slots"
	printf '%s' "${3:-{\}}" > "$work/$1/settings"
}

# ---------------------------------------------------------------- the screenpack game
# Start on the welcome screen opens the title menu; Down, A: VS Mode; both
# players pick Kung Fu Man (and a colour); a random stage; the round's intro
# dialogue is skipped; then both players move and attack.
frames=2300
fight=(--press 400:P1Start:6 --press 480:P1Down:3 --press 520:P1A:3 --press 640:P1A:3 --press 700:P2A:3
	--press 780:P1A:3 --press 860:P1A:3 --press 920:P2A:3 --press 1000:P1A:3 --press 1080:P1A:3 --press 1160:P1A:3
	--press 1620:P1A:3 --press 1680:P1A:3 --press 1740:P1A:3 --press 1800:P1Right:120 --press 1830:P2Left:60
	--press 1930:P1A:4 --press 1950:P1B:4 --press 1970:P2X:4 --press 1990:P1C:4 --press 2010:P2Y:4
	--press 2030:P1Down:20 --press 2040:P1A:4 --press 2080:P2Z:4 --press 2100:P1X:4 --press 2150:P1Right:60 --press 2160:P1Y:4)
mkwork game "$root/build/tests/test-game.zip"
echo "== the screenpack game ($frames frames: VS Mode, Kung Fu Man against Kung Fu Man, a fight)"
"$native" "$work/game" --frames $frames "${fight[@]}" --screenshot "60:$work/game60.tga" > "$work/n.txt" 2> "$work/n.err" &
"$wbx" "$core" "$work/game" --frames $frames "${fight[@]}" > "$work/w.txt" 2> "$work/w.err"
wait
same equivalence "$work/n.txt" "$work/w.txt" "native = sandbox, $frames frames: every picture, the sound, the steps"
"$wbx" "$core" "$work/game" --frames $frames "${fight[@]}" --session-at 2000 > "$work/s.txt" 2> "$work/s.err" &
"$wbx" "$core" "$work/game" --frames 300 --rerecord > "$work/r300.txt" 2> "$work/r300.err" &
"$wbx" "$core" "$work/game" --frames 300 > "$work/w300.txt" 2> "$work/w300.err"
wait
same session "$work/s.txt" "$work/w.txt" "saved at frame 2000 (in the fight), loaded into a new host = straight"
same rerecord "$work/r300.txt" "$work/w300.txt" "save+load before each of the first 300 frames = straight ($(sed -n 's/stateBytes=//p' "$work/r300.err") state bytes)"

late=("${fight[@]}")
for i in "${!late[@]}"; do [ "${late[$i]}" = "1930:P1A:4" ] && late[$i]="1931:P1A:4"; done
"$native" "$work/game" --frames $frames "${late[@]}" > "$work/late.txt" 2> /dev/null
if [ "$(value "$work/late.txt" videoHash)" != "$(value "$work/n.txt" videoHash)" ]; then
	pass "teeth: P1's first punch one frame later is another run (the comparison sees it)"
else
	fail "teeth: P1's first punch one frame later gave the same pictures"
fi

# ---------------------------------------------------------------- the probe
echo "== the probe (tests/probe)"
mkwork probe "$root/build/tests/probe.zip"
pf=130
probe_movie=(--press 10:P1A:2 --press 20:P2Start,P1Up:1 --press 30:P4Menu:1 --press 40:P1C,P1W:1 --press 50:Escape:1 --press 90:P3Y:1)
"$native" "$work/probe" --frames $pf "${probe_movie[@]}" > "$work/pn.txt" 2> "$work/pn.err" &
"$wbx" "$core" "$work/probe" --frames $pf "${probe_movie[@]}" > "$work/pw.txt" 2> "$work/pw.err"
wait
same equivalence "$work/pn.txt" "$work/pw.txt" "the probe: native = sandbox, $pf frames, every picture, the sound and the $(grep -c '^probe' "$work/pn.txt") lines it printed"
"$wbx" "$core" "$work/probe" --frames $pf "${probe_movie[@]}" --rerecord > "$work/pr.txt" 2> "$work/pr.err" &
"$wbx" "$core" "$work/probe" --frames $pf "${probe_movie[@]}" --session-at 25 > "$work/ps.txt" 2> "$work/ps.err"
wait
same rerecord "$work/pr.txt" "$work/pw.txt" "the probe saved and loaded before every frame = straight ($(sed -n 's/stateBytes=//p' "$work/pr.err") state bytes)"
same session "$work/ps.txt" "$work/pw.txt" "the probe saved at frame 25, between two presses, loaded into a new host = straight"

# turbo on the game, whose welcome screen moves (the probe draws nothing,
# so its pictures are the same read back or not)
"$native" "$work/game" --frames 460 --press 400:P1Start:6 --turbo > "$work/gt.txt" 2> /dev/null &
"$native" "$work/game" --frames 460 --press 400:P1Start:6 > "$work/gn.txt" 2> /dev/null
wait
digests "$work/gt.txt" | grep -v '^videoHash=' > "$work/gt.d"
digests "$work/gn.txt" | grep -v '^videoHash=' > "$work/gn.d"
if [ -s "$work/gn.d" ] && cmp -s "$work/gt.d" "$work/gn.d" && [ "$(value "$work/gt.txt" videoHash)" != "$(value "$work/gn.txt" videoHash)" ]; then
	pass "turbo: the game's first 230 frames not read back - the rest's pictures, the sound and the steps the same; the first half's pictures not there"
else
	fail "turbo"; diff "$work/gt.d" "$work/gn.d" | head
fi

has renderer "$work/pw.err" "Using OpenGL 4.5 (Core Profile) Mesa 24.0.9 (llvmpipe (LLVM 18.1.8, 128 bits))" "the game draws on llvmpipe with 128-bit vectors (the pinned CPU) in the sandbox"
has renderer "$work/pn.err" "Using OpenGL 4.5 (Core Profile) Mesa 24.0.9 (llvmpipe (LLVM 18.1.8, 128 bits))" "and in the native build, whatever this computer's CPU"
LP_NATIVE_VECTOR_WIDTH=256 "$native" "$work/probe" --frames 2 > /dev/null 2> "$work/pn256.err"
has renderer "$work/pn256.err" "128 bits" "the native build ignores this computer's environment (LP_NATIVE_VECTOR_WIDTH=256 was set)"

has clock "$work/pn.txt" "probe start date=2000-01-01T00:00:00 seed=[]" "the game starts on 2000-01-01, the default Starting Clock"
has clock "$work/pn.txt" "probe f=59 date=00:00:00 " "59 frames in, less than a second has gone by"
has clock "$work/pn.txt" "probe f=60 date=00:00:01 " "after 60 frames a second has gone by"
GATE_STALL_US=30000 "$native" "$work/probe" --frames 40 "${probe_movie[@]}" > "$work/stall.txt" 2> /dev/null
"$native" "$work/probe" --frames 40 "${probe_movie[@]}" > "$work/nostall.txt" 2> /dev/null
same clock "$work/stall.txt" "$work/nostall.txt" "the computer waiting 30 ms before every frame changes nothing the game sees"
mkwork probe2023 "$root/build/tests/probe.zip" '{"startTime": 1700000000}'
"$native" "$work/probe2023" --frames 3 > "$work/p2023.txt" 2> /dev/null
has clock "$work/p2023.txt" "probe start date=2023-11-14T22:13:20" "Starting Clock 1700000000 is the date the game reads"

rnd() { sed -n "s/^probe f=$2 .* rnd=\([0-9]*\) .*/\1/p" "$1"; }
if [ -n "$(rnd "$work/pn.txt" 0)" ] && [ "$(rnd "$work/pn.txt" 0)" = "$(rnd "$work/pw.txt" 0)" ] && [ "$(rnd "$work/p2023.txt" 0)" != "$(rnd "$work/pn.txt" 0)" ]; then
	pass "random: the engine's first random number is $(rnd "$work/pn.txt" 0) in both builds, and $(rnd "$work/p2023.txt" 0) from another Starting Clock"
else
	fail "random: $(rnd "$work/pn.txt" 0) native, $(rnd "$work/pw.txt" 0) sandbox, $(rnd "$work/p2023.txt" 0) from 2023"
fi

has controls "$work/pn.txt" "in=P1a" "P1 A held from frame 10 is P1's a at frame 12"
has controls "$work/pn.txt" "probe f=22 " "the game reads its controls every frame"
has controls "$work/pn.txt" "in=P1U,P2s" "P1 Up and P2 Start together"
has controls "$work/pn.txt" "in=P4m" "P4 Menu (the Back button)"
has controls "$work/pn.txt" "in=P1c,P1w" "P1 C and W, the two triggers"
has controls "$work/pn.txt" "in=Esc" "Escape"
has controls "$work/pn.txt" "in=P3y" "P3 Y"

echo "== videos (tests/video: beeps.webm, under the screenpack's logo video looping)"
mkwork video "$root/build/tests/video-probe.zip"
vf=300
vshots=()
for f in 20 58 59 64 65 118 119 124 125 260; do vshots+=(--screenshot "$f:$work/video/v$f.tga"); done
"$native" "$work/video" --frames $vf --audio "$work/video/n.raw" "${vshots[@]}" > "$work/vn.txt" 2> "$work/vn.err" &
"$wbx" "$core" "$work/video" --frames $vf > "$work/vw.txt" 2> "$work/vw.err"
wait
same equivalence "$work/vn.txt" "$work/vw.txt" "the video probe: native = sandbox, $vf frames, every picture and the sound"
"$wbx" "$core" "$work/video" --frames $vf --session-at 90 > "$work/vs.txt" 2> "$work/vs.err" &
"$wbx" "$core" "$work/video" --frames 130 --rerecord > "$work/vr.txt" 2> "$work/vr.err" &
"$wbx" "$core" "$work/video" --frames 130 > "$work/vw130.txt" 2> "$work/vw130.err"
wait
same session "$work/vs.txt" "$work/vw.txt" "the video probe saved at frame 90, between the two beeps, loaded into a new host = straight"
same rerecord "$work/vr.txt" "$work/vw130.txt" "the video probe saved and loaded before each of its first 130 frames = straight ($(sed -n 's/stateBytes=//p' "$work/vr.err") state bytes)"
python3 "$root/tests/check-video.py" "$work/video" "$work/game60.tga" > "$work/video/checks.txt" 2>&1
for what in pictures sound loop logo; do
	line="$(grep -E "^(ok|bad) $what: " "$work/video/checks.txt" | head -1)"
	case "$line" in
		ok*) pass "videos: ${line#ok $what: }" ;;
		bad*) fail "videos: ${line#bad $what: }" ;;
		*) fail "videos: $what: no answer from check-video.py ($(tail -1 "$work/video/checks.txt"))" ;;
	esac
done

# ---------------------------------------------------------------- older games
echo "== older games (tests/make-legacy-game.sh: the screenpack game made for Ikemen GO v0.99.0)"
mkwork legacy "$root/build/tests/legacy-game.zip"
mkdir -p "$work/legacy-save" "$work/legacy-save-w"
"$native" "$work/legacy" --frames $frames "${fight[@]}" --screenshot "$((frames - 1)):$work/legacy-last.tga" \
	--savedata-out "$work/legacy-save" > "$work/ln.txt" 2> "$work/ln.err" &
"$wbx" "$core" "$work/legacy" --frames $frames "${fight[@]}" --savedata-out "$work/legacy-save-w" > "$work/lw.txt" 2> "$work/lw.err"
wait
same "older games" "$work/ln.txt" "$work/lw.txt" "the game made for v0.99.0: native = sandbox, $frames frames, VS Mode to a fight, and the files it wrote"
has "older games" "$work/ln.txt" "The game was made for an Ikemen GO older than v1.0: 23 of its copies of the engine's files are set aside for the core's own" "v0.99.0's 23 scripts and common files are recognized (with Windows line ends) and set aside for the core's"
has "older games" "$work/ln.txt" "Its old modules replaced by their current versions: bossrush" "the 2023 Boss Rush module is replaced by its current version"
has "older games" "$work/ln.txt" "Its old modules left out, as Ikemen GO no longer has them: rank" "the Rank module, which Ikemen GO no longer has, is left out"
ini="$work/legacy-save/save/config.ini"
if grep -qE '^Time += 45$' "$ini" && grep -qE '^Life += 80$' "$ini" && grep -qE '^Motif += data/ikemen1/system.def$' "$ini" &&
   grep -qE '^GameWidth += 640$' "$ini" && grep -qE '^GameHeight += 480$' "$ini" &&
   [ "$(python3 -c "import struct,sys; print('%dx%d' % struct.unpack_from('<HH', open(sys.argv[1],'rb').read(), 12))" "$work/legacy-last.tga" 2>/dev/null)" = 640x480 ]; then
	pass "older games: save/config.json is the game's config.ini (round time 45, life 80%, its motif) over v0.99's defaults: the picture is v0.99's 640x480, not v1.0's 1280x720"
else
	fail "older games: config.ini: $(grep -E '^(Time|Life|Motif|GameWidth|GameHeight) ' "$ini" 2>/dev/null | tr -s ' ' | tr '\n' ';')"
fi
mkwork legacy-broken "$root/build/tests/legacy-broken.zip"
"$native" "$work/legacy-broken" --frames 60 > "$work/lb.txt" 2> "$work/lb.err"
if ! grep -q "made for an Ikemen GO older" "$work/lb.txt" && grep -q "^loadError=" "$work/lb.txt" && grep -q "^Error: external/script/main.lua:" "$work/lb.txt"; then
	pass "older games: with one line added to main.lua it is no version the core knows, and it is left as it is (v0.99's script then stops the v1.0 engine: $(grep -m1 -o 'main.lua:[0-9]*: .*' "$work/lb.txt"))"
else
	fail "older games: the changed main.lua: $(grep -m1 "made for\|loadError" "$work/lb.txt")"
fi

# ---------------------------------------------------------------- media
echo "== media (tests/media: every music file and sound through the engine's playback, against ffmpeg)"
nmedia="$root/build/native-media/run-native"
wmedia="$root/build/guest-media/run-wbx"
cmedia="$root/build/guest-media/core.wbx"
media_check() { # media_check <test dir> <zip> <what>
	mkwork "$1" "$2"
	"$nmedia" "$work/$1" --frames 1 > "$work/$1-n.txt" 2> "$work/$1-n.err" &
	"$wmedia" "$cmedia" "$work/$1" --frames 1 > "$work/$1-w.txt" 2> "$work/$1-w.err"
	wait
	python3 "$root/tests/media/check-media.py" "$2" "$work/$1-n.txt" "$work/$1-w.txt" > "$work/$1-check.txt" 2>&1
	local rc=$? summary
	summary="$(tail -1 "$work/$1-check.txt")"
	if [ "$rc" -eq 0 ] && grep -q "native = sandbox" "$work/$1-check.txt"; then
		pass "media: $3: ${summary#media: }"
	else
		fail "media: $3: $summary"; grep '^problem' "$work/$1-check.txt" | head -10
	fi
	grep '^note' "$work/$1-check.txt" | sed 's/^/     /'
}
media_check media "$root/build/tests/media-game.zip" "the media test game"
mline() { grep -P "^music\tsound/$1\t" "$work/media-n.txt" | cut -f3,5; }
if [ "$(mline junk-end.mp3)" = "$(mline song.mp3)" ] && [ "$(mline song.mp3 | cut -f1)" = ok ]; then
	pass "media: the MP3 ending in junk that looks like frame headers plays as the same MP3 without it ($(mline junk-end.mp3 | tr '\t' ' '))"
else
	fail "media: junk-end.mp3: $(mline junk-end.mp3) against song.mp3: $(mline song.mp3)"
fi
if [ -n "$(mline song.mpc)" ]; then
	if [ "$(mline song.mpc | cut -f1)" = ok ]; then
		pass "media: Musepack, which Ikemen GO has no decoder for, plays through the core's FFmpeg ($(mline song.mpc | tr '\t' ' '))"
	else
		fail "media: song.mpc: $(mline song.mpc)"
	fi
else
	skip "media: Musepack: mpcenc is not installed, so the media test game has no Musepack file"
fi
media_check media-sp "$root/build/tests/test-game.zip" "the screenpack game"

# ---------------------------------------------------------------- KOF Special
echo "== kof special (IKEMEN_KOF_ZIP: a fan game made for v0.99.0, kept out of this repository)"
if [ -n "${IKEMEN_KOF_ZIP:-}" ] && [ -f "$IKEMEN_KOF_ZIP" ]; then
	media_check kof "$IKEMEN_KOF_ZIP" "KOF Special"
	if grep -q "^note: 89 sounds under 128 bytes are left out" "$work/kof-check.txt" &&
	   [ "$(grep -c '^note' "$work/kof-check.txt")" = 2 ]; then
		pass "kof special: the media left out are only its 89 placeholder sounds of 110 bytes (Ikemen GO's rule, kept) and one empty file"
	else
		fail "kof special: notes: $(grep '^note' "$work/kof-check.txt" | tr '\n' ';')"
	fi
	# Arcade: past the intros (Start), the title's Arcade, Single Mode, the
	# first character, then attacks through two rounds
	python3 - "$work/kof.mov" <<'PY'
import sys
held = [set() for _ in range(6000)]
def press(at, toks, n):
    for f in range(at, min(6000, at + n)):
        held[f].update(toks.split(","))
for f in range(240, 1081, 60): press(f, "P1Start", 4)
for f in (1150, 1250, 1350, 1450): press(f, "P1A", 4)
for f in range(1500, 5901, 40):
    press(f, *[("P1Right", 30), ("P1A", 4), ("P1B", 4), ("P1Down,P1C", 6), ("P1X", 4), ("P1Y", 4)][(f // 40) % 6])
open(sys.argv[1], "w").write("".join(",".join(sorted(h)) + "\n" for h in held))
PY
	"$native" "$work/kof" --frames 6000 --movie "$work/kof.mov" --screenshot "5999:$work/kof-last.tga" > "$work/kn.txt" 2> "$work/kn.err" &
	"$wbx" "$core" "$work/kof" --frames 6000 --movie "$work/kof.mov" > "$work/kw.txt" 2> "$work/kw.err"
	wait
	same "kof special" "$work/kn.txt" "$work/kw.txt" "Arcade from boot to the second round: native = sandbox, 6000 frames"
	"$wbx" "$core" "$work/kof" --frames 6000 --movie "$work/kof.mov" --session-at 5000 > "$work/ks.txt" 2> "$work/ks.err"
	same "kof special" "$work/ks.txt" "$work/kw.txt" "saved at frame 5000, in the second round, loaded into a new host = straight ($(sed -n 's/stateBytes=//p' "$work/ks.err" | head -1) state bytes)"
	has "kof special" "$work/kn.txt" "Its old modules replaced by their current versions: bossrush, scorechallenge, timechallenge, vs100kumite" "recognized as made for v0.99.0; its four old modes replaced, Rank left out"
else
	skip "kof special: IKEMEN_KOF_ZIP does not name a copy of the game"
fi

echo "== save data (the probe writes save/probe.txt)"
mkdir -p "$work/sdn" "$work/sdw" "$work/sds"
"$native" "$work/probe" --frames 30 --savedata-out "$work/sdn" > "$work/sdn.txt" 2> /dev/null
"$wbx" "$core" "$work/probe" --frames 30 --savedata-out "$work/sdw" > "$work/sdw.txt" 2> /dev/null
"$wbx" "$core" "$work/probe" --frames 30 --session-at 10 --savedata-out "$work/sds" > "$work/sds.txt" 2> /dev/null
if [ "$(cat "$work/sdn/save/probe.txt" 2>/dev/null)" = "written on 2000-01-01" ] && [ -f "$work/sdn/save/config.ini" ] && [ -f "$work/sdn/save/stats.json" ] &&
   diff -r "$work/sdn" "$work/sdw" > /dev/null && diff -r "$work/sdw" "$work/sds" > /dev/null && [ "$(find "$work/sdn" -type f | wc -l)" = 3 ]; then
	pass "save data: Export Save Data is what the game wrote in save/ (its config.ini, stats.json and the probe's file), by path; native = sandbox = a session"
else
	fail "save data: export: $(cd "$work/sdn" 2>/dev/null && find . -type f | sort | tr '\n' ' ')"
fi
seed() { # seed <dir> <slots JSON> <file to bring>...
	local d="$work/$1" slots="$2"; shift 2
	mkdir -p "$d"
	cp "$root/build/tests/probe.zip" "$d/"
	printf '%s' "$slots" > "$d/slots"
	printf '{}' > "$d/settings"
	for f in "$@"; do cp "$f" "$d/"; done
}
printf 'hello from a project' > "$work/seed.txt"
seed seed1 '{"game":["probe.zip"],"savedata":["seed.txt"]}' "$work/seed.txt"
"$native" "$work/seed1" --frames 2 > "$work/seed1.txt" 2> /dev/null
has "save data" "$work/seed1.txt" "seed=[hello from a project]" "a project's save file is in save/ when the game starts"
python3 -c "
import zipfile
z = zipfile.ZipFile('$work/save.zip', 'w'); z.writestr('save/seed.txt', 'hello from a zip'); z.close()"
seed seedzip '{"game":["probe.zip"],"savedata":["save.zip"]}' "$work/save.zip"
"$native" "$work/seedzip" --frames 2 > "$work/seedzip.txt" 2> /dev/null
"$wbx" "$core" "$work/seedzip" --frames 2 > "$work/seedzipw.txt" 2> /dev/null
has "save data" "$work/seedzip.txt" "seed=[hello from a zip]" "the export's zip goes back with its folders"
same "save data" "$work/seedzip.txt" "$work/seedzipw.txt" "the zip read back: native = sandbox"
python3 -c "
import zipfile
z = zipfile.ZipFile('$work/bad.zip', 'w'); z.writestr('../escape.txt', 'no'); z.close()"
seed seedbad '{"game":["probe.zip"],"savedata":["bad.zip"]}' "$work/bad.zip"
"$native" "$work/seedbad" --frames 1 > "$work/seedbad.txt" 2> /dev/null
has "save data" "$work/seedbad.txt" 'loadError=the project'"'"'s save data could not be used: bad.zip: "../escape.txt" is not a name inside the game'"'"'s folder' "a zip holding a name outside the game's folder is refused, saying which"

echo "== refusals"
mkdir -p "$work/nogame"
printf '{"game":["missing.zip"]}' > "$work/nogame/slots"; printf '{}' > "$work/nogame/settings"
"$native" "$work/nogame" --frames 1 > "$work/nogame.txt" 2> /dev/null
if grep -q "^loadError=the game's zip (missing.zip) could not be read" "$work/nogame.txt"; then
	pass "refusals: a game that is not there says so"
else
	fail "refusals: missing game: $(grep loadError "$work/nogame.txt")"
fi
mkdir -p "$work/notzip"
head -c 4096 /dev/zero | tr '\0' 'x' > "$work/notzip/game.zip"
printf '{"game":["game.zip"]}' > "$work/notzip/slots"; printf '{}' > "$work/notzip/settings"
"$native" "$work/notzip" --frames 1 > "$work/notzip.txt" 2> /dev/null
if grep -q "^loadError=the game's zip (game.zip) could not be read: zip: not a valid zip file" "$work/notzip.txt"; then
	pass "refusals: a file that is not a zip: $(sed -n 's/^loadError=//p' "$work/notzip.txt")"
else
	fail "refusals: not a zip: $(grep loadError "$work/notzip.txt")"
fi

echo
echo "$passed passed, $fails failed, $skipped skipped"
[ "$fails" -eq 0 ]
