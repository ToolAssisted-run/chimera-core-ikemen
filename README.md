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

Built and tested on this machine; not published. Chimera issue 324.

- Ikemen GO games drawn with its OpenGL 3.3 renderer on a software OpenGL
  inside the core (Mesa's llvmpipe, made to generate the same code on every
  computer).
- Tried: the Ikemen GO screenpack (the default motif its releases carry,
  with Kung Fu Man) from boot through VS Mode to a fight, and this
  repository's probe. The sandboxed core and a plain native build agree on
  every picture, the sound and every step; savestates land where the
  straight run does; Chimera on Linux and on Windows draws the same
  pictures. No other game has been tried yet.
- The game's state is named for Chimera's tools (RAM Watch, freezes, Lua's
  `game.*`): the round, its time, the random seed, and each fighter's life,
  power, position, state and gauges, most of them writable.
- Not there: background videos (the core has no FFmpeg; a video is skipped,
  as Ikemen GO skips one it cannot read), netplay, the Vulkan renderer, the
  GPU. A 1280x720 game runs at about 7 to 10 frames a second on a fast
  computer.

## What you bring

The game: an Ikemen GO game folder (the one holding `chars/`, `stages/`,
`data/` and the rest, as an Ikemen GO release unpacks), zipped. The zip may
hold the folder itself or its contents. What the core does not find in it -
the engine's own `data/`, `external/` and `font/` files - it brings itself,
from the Ikemen GO it is built with.

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

This repository's own code is MIT, and so is Ikemen GO. Go is BSD-3-Clause;
the Go modules inside are under their own permissive licences; libxmp and
Mesa are MIT, LLVM is Apache 2.0 with the LLVM exception. The package carries
every licence text. See [LICENSE](LICENSE).
