# AGENTS.md - chimera-core-ikemen

Ikemen GO 1.0.0 as a Chimera core: the engine built as a C archive with a Go
1.27.3 of this repository's own, drawn by Mesa's llvmpipe behind OSMesa. The
user brings a game folder as a zip. Read Chimera's `docs/new-core.md` and
this repository's `docs/PLAN.md` first.

## Layout

- `extern/Ikemen-GO` - Ikemen GO at v1.0.0, a submodule. Never built in and
  never edited: `build-ikemen.sh` copies it to `build/ikemen-src` and
  applies `patches/` there.
- `extern/Ikemen-GO-Screenpack` - the screenpack Ikemen GO 1.0.0 shipped
  with, a submodule; the test game is made from it, and the core carries its
  `data/gofx` (the common effects v1.0's settings name).
- `extern/Ikemen-GO-modules` - Ikemen GO's modules repository, a submodule:
  the current Boss Rush, Score Challenge, Time Challenge and VS 100 Kumite,
  which take the place of their old versions in an older game.
- `go/chimera` - the core's files added to Ikemen GO's package main:
  `chimera_core.c` (Chimera's calls, OSMesa, the frame handover),
  `chimera_core.go` (the Go half: start, sound, controls, configuration),
  `chimera_fs.go` (the game's disk), `chimera_util.go` (the desktop helpers),
  `chimera_video.go` (background videos, decoded on the frame),
  `chimera_music.go` (music in a format Ikemen GO cannot read, through
  FFmpeg), `chimera_legacy.go` (games made for an older Ikemen GO; its lists
  `chimera_legacy_files.txt` and `chimera_legacy_config.json` are written by
  `waterbox/make-legacy-list.py`), `chimera_props.go` (the game's
  properties).
- `go/sdl2` - a stand-in for SDL 2's Go binding. FFmpeg's binding (reisen) is
  Ikemen GO's own, over the FFmpeg `build-ffmpeg.sh` makes.
- `patches/` - numbered patches to Ikemen GO; `patches/go-mp3/` - to the MP3
  decoder, a Go module (build-ikemen.sh puts a patched copy in its place).
- `waterbox/go-patches` - the patches to Go: `common/` in both toolchains,
  `guest/` in the sandbox's.
- `waterbox/` - the scripts and the package's declarations
  (`waterbox.config`, `file_slots.json`, `default_keybinds.json`,
  `package-licenses.json`), the harness (`gate-harness.h`, `run-native.c`,
  `run-wbx.c`, `input-names.h`), `run-gate.sh`.
- `tests/` - the test games' scripts (`make-test-game.sh`, `make-probe.sh`,
  `probe/`, `make-video-probe.sh`, `video/`, `check-video.py`,
  `make-legacy-game.sh`, `make-media-game.sh`), `media/` (the media check:
  a file built only into a test build, `CHIMERA_VARIANT=media`, and
  `check-media.py`), `run-frontend.sh` and its helpers.
- `tools/` - generators (`gen-sdl-consts.py`, `gen-input-names.py`) and
  `tga2png.py`.
- `build/` - every output. Ignored by git.

## Commands, in order

    mb=<chimera>/extern/chimera-common-minibox
    waterbox/setup-go.sh
    waterbox/build-llvm.sh native && waterbox/build-llvm.sh guest -m $mb
    waterbox/setup-mesa.sh -n && waterbox/setup-mesa.sh -m $mb
    waterbox/build-libxmp.sh native && waterbox/build-libxmp.sh guest -m $mb
    waterbox/build-ffmpeg.sh native && waterbox/build-ffmpeg.sh guest -m $mb
    waterbox/make-native-libm.sh $mb
    waterbox/build-ikemen.sh native -m $mb && waterbox/build-ikemen.sh guest -m $mb
    waterbox/link-core.sh native -m $mb && waterbox/link-core.sh guest -m $mb
    waterbox/run-gate.sh -m $mb                      # the core's tests (it also
                                                     # builds the media check's
                                                     # test builds)
    waterbox/build-package.sh -r <chimera>           # the package, installed
    tests/run-frontend.sh --chimera-root <chimera>   # through Chimera

## Rules

- Everything the game can observe comes from the core: no host clock (Go's
  `time.Now` is the machine's, go-patches/common/0003), no host file (every
  file call goes through `chimera_fs.go`), no environment.
- Nothing runs beside the frames: a goroutine that works while frames go by
  (a loader, a sound pusher) makes the native build differ from the
  sandbox. Make it finish before the frame ends (patches/0006), or do its
  work on the frame (background videos, patches/0007).
- The native reference links the sandbox's math (`make-native-libm.sh`);
  never let it fall back to glibc's. Go's own maths is Go's in both builds.
- llvmpipe sees one CPU everywhere (mesa-patches/0001); FFmpeg and libvpx
  are plain C, with no threads (build-ffmpeg.sh).
- A change to `waterbox.config`'s buttons changes `chimera_core.h`,
  `padControls` in `chimera_core.go` and `input-names.h`
  (`tools/gen-input-names.py`) the same way, in the same order.
- When the pinned Ikemen GO changes, run `waterbox/make-legacy-list.py`
  (it reads extern/Ikemen-GO's history: `git fetch --tags` first) and
  commit what it writes.
- A long loop inside one frame never lets the sandbox's one thread run Go's
  collector: memory grows until the frame ends (the media check, which runs
  in one go, collects after each file).
- Every new test is broken on purpose once and seen to fail.
- Write in plain language; prose is ASCII. Commits: `type(scope): what
  changed`, body with how it was tested, Chimera's trailers.
- Stop a build by its PID, never with `pkill -f`.
