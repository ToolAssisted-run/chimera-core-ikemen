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
  with, a submodule; only the test game is made from it.
- `go/chimera` - the core's files added to Ikemen GO's package main:
  `chimera_core.c` (Chimera's calls, OSMesa, the frame handover),
  `chimera_core.go` (the Go half: start, sound, controls, configuration),
  `chimera_fs.go` (the game's disk), `chimera_util.go` (the desktop helpers).
- `go/sdl2`, `go/reisen` - stand-ins for SDL 2's and FFmpeg's Go bindings.
- `patches/` - numbered patches to Ikemen GO.
- `waterbox/go-patches` - the patches to Go: `common/` in both toolchains,
  `guest/` in the sandbox's.
- `waterbox/` - the scripts and the package's declarations
  (`waterbox.config`, `file_slots.json`, `default_keybinds.json`,
  `package-licenses.json`), the harness (`gate-harness.h`, `run-native.c`,
  `run-wbx.c`, `input-names.h`), `run-gate.sh`.
- `tests/` - the test games' scripts (`make-test-game.sh`, `make-probe.sh`,
  `probe/`), `run-frontend.sh` and its helpers.
- `tools/` - generators (`gen-sdl-consts.py`, `gen-input-names.py`) and
  `tga2png.py`.
- `build/` - every output. Ignored by git.

## Commands, in order

    mb=<chimera>/extern/chimera-common-minibox
    waterbox/setup-go.sh
    waterbox/build-llvm.sh native && waterbox/build-llvm.sh guest -m $mb
    waterbox/setup-mesa.sh -n && waterbox/setup-mesa.sh -m $mb
    waterbox/build-libxmp.sh native && waterbox/build-libxmp.sh guest -m $mb
    waterbox/make-native-libm.sh $mb
    waterbox/build-ikemen.sh native -m $mb && waterbox/build-ikemen.sh guest -m $mb
    waterbox/link-core.sh native -m $mb && waterbox/link-core.sh guest -m $mb
    waterbox/run-gate.sh -m $mb                      # the core's tests
    waterbox/build-package.sh -r <chimera>           # the package, installed
    tests/run-frontend.sh --chimera-root <chimera>   # through Chimera

## Rules

- Everything the game can observe comes from the core: no host clock (Go's
  `time.Now` is the machine's, go-patches/common/0003), no host file (every
  file call goes through `chimera_fs.go`), no environment.
- Nothing runs beside the frames: a goroutine that works while frames go by
  (a loader, a sound pusher) makes the native build differ from the
  sandbox. Make it finish before the frame ends (patches/0006).
- The native reference links the sandbox's math (`make-native-libm.sh`);
  never let it fall back to glibc's. Go's own maths is Go's in both builds.
- llvmpipe sees one CPU everywhere (mesa-patches/0001).
- A change to `waterbox.config`'s buttons changes `chimera_core.h`,
  `padControls` in `chimera_core.go` and `input-names.h`
  (`tools/gen-input-names.py`) the same way, in the same order.
- Every new test is broken on purpose once and seen to fail.
- Write in plain language; prose is ASCII. Commits: `type(scope): what
  changed`, body with how it was tested, Chimera's trailers.
- Stop a build by its PID, never with `pkill -f`.
