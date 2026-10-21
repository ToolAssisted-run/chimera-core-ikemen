# chimera-core-ikemen

A core for [Chimera](https://github.com/ToolAssisted-run/chimera), the
frontend for tool-assisted speedruns, that plays games made with
**[Ikemen GO](https://github.com/ikemen-engine/Ikemen-GO)**, the open-source
fighting game engine that runs M.U.G.E.N characters, stages and screenpacks.
It is Ikemen GO 1.0.0 built for Chimera's sandbox, and produces one file,
`ikemen.chimeraCore`, that goes in Chimera's `Cores` folder.

Ikemen GO is written in Go, so the core is built with a Go of its own: Go
1.27.3 with a few patches that make a Go program run in the sandbox (its
system calls, its threads' stacks, its clock).

## Status

Published: each push to `main` that passes the tests publishes a `dev`
release, and a dated nightly is made once a day when `main` moved. Chimera's
Core Manager lists it. The first published build is "Development build
ccaaa382 (made 2026-10-21 15:38 CEST)". Chimera issue 324.

- Ikemen GO games drawn with its OpenGL 3.3 renderer on a software OpenGL
  inside the core (Mesa's llvmpipe, made to generate the same code on every
  computer).
- Background videos play through FFmpeg, built with what Ikemen GO's own
  releases read (WebM with VP8 or VP9 pictures, transparency, Opus or Vorbis
  sound) and decoded on each frame, so that every computer shows the same
  pictures and plays the same sound. Tried: VP9 with and without
  transparency, and Opus; VP8 and Vorbis not yet.
- Games made for an older Ikemen GO (0.97 to 0.99) play too: the core
  recognizes the older release's own scripts in the game's folder and uses
  its v1.0 ones instead, as Ikemen GO's upgrade advice says, swaps the old
  Boss Rush, Score Challenge, Time Challenge and VS 100 Kumite modes for
  their current versions, and reads the old `save/config.json` settings.
- Every music file and sound plays as ffmpeg decodes it: OGG, MP3 (also one
  that ends in junk, which Ikemen GO's decoder used to refuse), FLAC, WAV,
  tracker modules, and Musepack, which Ikemen GO has no decoder for, through
  the core's FFmpeg. Ikemen GO's own rule stays: a sound under 128 bytes in
  a character's sound file is not played.
- Tried: the Ikemen GO screenpack (the default motif its releases carry,
  with Kung Fu Man) from boot, with its logo video, through VS Mode to a
  fight; this repository's two probes (one plays a video with sound); and
  KOF Special, a fan game made for Ikemen GO 0.99 (not shared here): Arcade,
  VS Mode, Training, Survival, Boss Rush and Watch Mode, and all its 329
  music files and 13,447 sounds. The sandboxed core and a plain native build agree on every
  picture, the sound and every step; savestates land where the straight run
  does; Chimera on Linux and on Windows draws the same pictures.
- The game's state is named for Chimera's tools (RAM Watch, freezes, Lua's
  `game.*`): the round, its time, the random seed, and each fighter's life,
  power, position, state and gauges, most of them writable.
- Not there: netplay, the Vulkan renderer, the GPU. A 1280x720 game runs at
  about 7 to 10 frames a second on a fast computer.

## What you bring

The game: an Ikemen GO game folder (the one holding `chars/`, `stages/`,
`data/` and the rest, as an Ikemen GO release unpacks), zipped. The zip may
hold the folder itself or its contents. What the core does not find in it -
the engine's own `data/`, `external/` and `font/` files - it brings itself,
from the Ikemen GO it is built with. A folder made for Ikemen GO 0.97 to 0.99
is used as it is: the core sets aside the older engine files in it.

## Buttons and settings

- **Four players**, each a game controller in Ikemen GO's own default
  layout: the directions; A, B, C, X, Y, Z; Start; D and W; and Menu. Player
  1 is also on Ikemen GO's default keys (the arrows, Z X C, A S D, Enter).
- **Escape**, which leaves a menu or a match.
- **Starting Clock**: the date the game reads when it starts (movies need the
  same value). Ikemen GO also seeds its random numbers from it.

What the game writes (its `save/` folder) lives in the core's memory and is
carried by savestates. Game > Export Save Data writes it out, and a
project's "Save data" slot puts such files, or their `.zip`, back before the
game starts.

## Building and testing

[docs/BUILDING.md](docs/BUILDING.md) has every step. [docs/PLAN.md](docs/PLAN.md)
is the design log: what was decided, why, and what was measured.

## Licence

This repository's own code is MIT, and so are Ikemen GO and its modules;
its common effects (`data/gofx`) are CC BY 3.0. Go is BSD-3-Clause;
the Go modules inside are under their own permissive licences; libxmp and
Mesa are MIT, LLVM is Apache 2.0 with the LLVM exception; FFmpeg is LGPL 2.1
(linked statically; this repository builds the core again with a changed
FFmpeg) and libvpx BSD-3-Clause. The package carries every licence text. See
[LICENSE](LICENSE).
