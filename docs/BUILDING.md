# Building the Ikemen GO core

Everything is built on Linux (x86-64). The package is one file for Chimera on
Linux and on Windows.

## Requirements

- gcc and g++ (14 was used), binutils, make, cmake, ninja, meson, python3
  with `mako` and `packaging` for Mesa (setup-mesa.sh makes a private venv
  when the system's meson lacks them), curl, git, xz, patch.
- A Chimera checkout with miniBox built, for the sandbox's toolchain and host:

      mb=<chimera>/extern/chimera-common-minibox
      meson setup "$mb/build/meson-linux" "$mb" && meson compile -C "$mb/build/meson-linux"
      meson setup "$mb/build/meson-cpp" "$mb" -Dguest_cpp=true && meson compile -C "$mb/build/meson-cpp"

- No Go is needed: `setup-go.sh` fetches Go 1.27.3 (checked against its
  SHA-256) and makes the two toolchains from it. The Go modules Ikemen GO
  needs are fetched by Go from its module proxy the first time and checked
  against Ikemen GO's go.sum.

## Sources

- `extern/Ikemen-GO` (v1.0.0) and `extern/Ikemen-GO-Screenpack` (the commit
  of 2026-09-11, what 1.0.0 shipped with) are submodules:
  `git submodule update --init`.
- Go 1.27.3, LLVM 18.1.8, Mesa 24.0.9, libxmp 4.7.4, FFmpeg 7.1.5 and
  libvpx 1.15.2 are release tarballs fetched into `build/deps` by the
  scripts, each checked against a pinned SHA-256. `CHIMERA_DEPS_DIR` points
  them at another folder.

## Steps

    mb=<chimera>/extern/chimera-common-minibox
    waterbox/setup-go.sh                                   # build/go-native, build/go-guest
    waterbox/build-llvm.sh native                          # ~15 min
    waterbox/build-llvm.sh guest -m $mb                    # ~15 min
    waterbox/setup-mesa.sh -n                              # Mesa for the native build
    waterbox/setup-mesa.sh -m $mb                          # Mesa for the guest
    waterbox/build-libxmp.sh native && waterbox/build-libxmp.sh guest -m $mb
    waterbox/build-ffmpeg.sh native && waterbox/build-ffmpeg.sh guest -m $mb
    waterbox/make-native-libm.sh $mb                       # the sandbox's math, for the native build
    waterbox/build-ikemen.sh native -m $mb                 # build/native/libikemen.a
    waterbox/build-ikemen.sh guest -m $mb                  # build/guest/libikemen.a
    waterbox/link-core.sh native -m $mb                    # build/native/run-native
    waterbox/link-core.sh guest -m $mb                     # build/guest/core.wbx, build/guest/run-wbx

`build-ikemen.sh` copies the submodule to `build/ikemen-src`, applies
`patches/`, adds `go/chimera` to Ikemen GO's package main and the engine's
`data/`, `external/` and `font/` under it (the core carries them), puts
`go/sdl2` in place of SDL 2's binding, and builds a C archive with the tags
`chimera,kinc,netgo,osusergo` and `GOEXPERIMENT=arenas` (Ikemen GO's rollback
uses Go's arenas). FFmpeg's binding is Ikemen GO's own (reisen); it finds
`build-ffmpeg.sh`'s FFmpeg through pkg-config.

`build-ffmpeg.sh` builds what Ikemen GO's releases build (FFmpeg under the
LGPL: the Matroska/WebM reader, libvpx's VP8 and VP9 decoders, Opus and
Vorbis, the scale, pad, crop and format filters), but as plain C with no
threads, so that every computer decodes a video to the same bytes.

## The package

    waterbox/build-package.sh -m $mb             # build/package/ikemen.chimeraCore
    waterbox/build-package.sh -r <chimera>       # into <chimera>/build/Cores

It runs every guest step above, collects the licences of the Go modules
compiled in (`collect-go-licenses.sh`), and writes the package twice to check
that it is the same file.

## The tests

    waterbox/run-gate.sh -m $mb
    tests/run-frontend.sh --chimera-root <chimera>
    CHIMERA_CORES_DIR=build/package dotnet test \
        <chimera>/source/gui/Chimera.Tests.Client.Common/Chimera.Tests.Client.Common.csproj \
        -c Release --filter "FullyQualifiedName~InstalledCorePackagesTests|FullyQualifiedName~MnemonicUniquenessTests"

`run-gate.sh` makes the three test games (`tests/make-test-game.sh`,
`tests/make-probe.sh`, `tests/make-video-probe.sh`) and compares the native reference with the sandbox;
it says what each test compared. `run-frontend.sh` builds the package and
plays the test game through `chimera-run` and through Chimera's window under
Mono on Xvfb; it needs Chimera built (its engine installed and its
interface).

The harness by hand: a work folder holds the game's zip, a `slots` file
(`{"game":["test-game.zip"]}`) and a `settings` file (`{}`), then

    build/native/run-native <folder> --frames 600 --press 400:P1Start:6 --screenshot 599:shot.tga
    build/guest/run-wbx build/guest/core.wbx <folder> --frames 600 --press 400:P1Start:6

print the digests of every picture, the sound and the steps
(`tools/tga2png.py` turns a screenshot into a PNG).

## Troubleshooting

- "invalid reference to runtime.mbsyscall": the guest Go patches need the
  linkname in `sys_minibox_linux.go`; run `setup-go.sh` again (it remakes a
  toolchain whose patches changed).
- A Go build error about `X11/Xlib.h`: the guest build needs
  `waterbox/guest-compat` on its include path (build-ikemen.sh sets it).
- "arena: build constraints exclude all Go files": `GOEXPERIMENT=arenas` is
  missing.
- A core that waits for ever at a frame: something Ikemen GO started on a
  goroutine is waiting for the main thread; see patches/0006.
- "configured without LIBVPX_VP9_DECODER" from `build-ffmpeg.sh`: FFmpeg did
  not find libvpx; its `build/ffmpeg-<flavour>-work/ffmpeg/configure.log`
  says why (the libvpx it built is in `build/ffmpeg-<flavour>/lib`).
- `tests/video/beeps.webm` is made by `tests/make-beeps-video.sh` with a host
  FFmpeg; it is committed, so the tests do not need one.
