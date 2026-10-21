# The Ikemen GO core: the design log

What was decided, why, and what was measured. Newest last.

## The request (2026-10-20)

Chimera issue 324 asked for Ikemen GO, the open-source M.U.G.E.N-compatible
fighting game engine. The owner first deferred it: Ikemen GO is written in
Go, and the sandbox runs programs built against its own C library, which a Go
program does not use. After a deeper analysis and a trial (below) the owner
asked for the core to be built, in a repository of its own and local, with
nothing published.

## The answers before any code (Chimera's docs/new-core.md, section 1)

- **A new core?** Yes. No core here runs Go, or a M.U.G.E.N engine.
- **Licence.** Ikemen GO is MIT. Go is BSD-3-Clause; the Go modules it is
  built from are MIT, BSD, Apache-2.0, the FreeType License (golang/freetype,
  dual with the GPL; the core takes the FreeType License) and the Unlicense.
  libxmp is MIT, Mesa MIT, LLVM Apache-2.0 with the LLVM exception. Binary
  and modified redistribution are allowed; the package carries every text.
  (FFmpeg, LGPL 2.1, and libvpx, BSD-3-Clause, came in on 2026-10-21 for
  background videos: below.)
- **One thread on one clock?** Go runs goroutines on threads of its own, and
  the sandbox runs one thread at a time and decides when each runs, so a Go
  program is one machine on one clock once its runtime calls the sandbox
  (the trial). Ikemen GO's rollback netplay is a good sign: its matches
  already replay the same from the same inputs.
- **The picture.** Ikemen GO draws with OpenGL 3.3 (or Vulkan, or GLES on
  Android). The core uses the OpenGL 3.3 renderer on Mesa's llvmpipe behind
  OSMesa, compiled into the core, as the Godot core does (the same Mesa
  24.0.9, LLVM 18.1.8 and the patch that pins llvmpipe to one CPU).
- **A recompiler?** Go is compiled ahead of time; llvmpipe compiles shaders
  with LLVM, pinned to one CPU.
- **What the user brings.** An Ikemen GO game folder, as a zip.
- **What CI can run.** The screenpack Ikemen GO 1.0.0 shipped with
  (a submodule; most of it CC BY 3.0, Elecbyte's Kung Fu Man and two stages
  non-commercial) and this repository's probe. Nothing of either is
  committed or packaged.
- **Size.** The guest is 103 MB (37 MB packaged). The layout gives 1 GiB of
  heap and 6 GiB of mmap space: the Go runtime reserves about 1.4 GiB of
  address space as it starts, most of it never touched.

## Go in the sandbox: the trial (2026-10-20)

Before the core, a trial asked whether a Go program can be a sandbox machine
at all: a test program with a frame loop, a loader goroutine, a ticker,
eight workers a frame, maps, select, deep recursion, a file read and a C call,
built as a C archive. With a Go 1.27.3 of its own (14 files changed in the
standard library's source; the compiler and linker are the release's):

- On Linux the computed numbers equalled a native build on all 3000 frames;
  two runs were the same, memory included (65 MB); saving and loading before
  every frame changed nothing; a state loaded in a new process reproduced the
  rest.
- On Windows the frames were Linux's. The heap, globals and runtime were
  byte-identical to Linux; only 19 to 23 stack pages differed, which is
  Windows' exception record written below the stack pointer when it reports
  the sandbox's write tracking - the residue every core has there.
- Negative controls: the processor's time counter put back made 17 bytes of
  memory differ between runs; goroutine stacks not marked as stacks killed
  the process on Windows at frame 0; no room below them sent a goroutine to
  address 0 on Windows. Linux ran fine in the last two.

The patches (waterbox/go-patches/guest), each kept here because the trial saw
the need:

1. **System calls go to the sandbox.** Go makes its system calls with the
   SYSCALL instruction (46 places in the runtime, package syscall and
   internal/runtime/syscall/linux), not through a C library. Each now calls
   `runtime·mbsyscall`, which keeps the registers SYSCALL keeps, moves the
   fourth argument to where the sandbox wants it, and calls the sandbox's
   trampoline. It answers three calls the sandbox lacks itself: sigaltstack
   (no signals: "disabled"), mincore and prlimit64 (ENOSYS, which Go takes).
2. **A library starts with no arguments, and the tick counter is the
   sandbox's clock.** musl calls a C library constructor with nothing, so
   the runtime gets a fixed argv, no environment and an auxv giving only the
   page size. The processor's time counter (RDTSC) was written into memory
   at start; it is now the sandbox's clock.
3. **No asynchronous preemption**: it is a signal, and the sandbox delivers
   none. Goroutines are preempted at function calls, as before Go 1.14.
4. **No poller.** There is no epoll; files are read blocking, and the poller
   only sleeps until the next timer (a futex wait with a timeout, as
   Plan 9's stub does).
5. **Goroutine stacks are stacks.** They come from Go's heap; the sandbox
   has to be told they are stacks (mmap with MAP_STACK, through the hook Go
   already has for OpenBSD), or on Windows the first push on a page it
   watches ends the process. And 16 KiB more room below every goroutine's
   stack pointer, for Windows' exception record (Go on Windows keeps 4 KiB).
   The smallest stack is then 32 KiB, so one stack size class.

## The shape of the core (2026-10-20)

- **Ikemen GO as a C archive.** `build-ikemen.sh` builds the submodule's
  copy with `-buildmode=c-archive`; Chimera's calls are C (chimera_core.c),
  and no Go code runs on the thread Chimera calls the core on: a goroutine
  locked to a thread of its own runs Ikemen GO's main, and the two halves
  hand frames over with a mutex and a condition variable.
- **A frame is a buffer swap.** Ikemen GO owns its loops (Lua menus, the
  match); every frame ends in `System.await`, which swaps the window's
  buffers. The swap is the frame's end: the core mixes the frame's sound,
  takes the picture, and waits for the next frame there.
- **SDL 2 is a stand-in.** Ikemen GO uses SDL 2 for its window, events,
  controllers and sound (about 220 names). `go/sdl2` is a Go package with
  the same names and types (the constants generated from SDL 2's headers by
  `tools/gen-sdl-consts.py`) that does a Chimera machine's job: one window,
  whose OpenGL context the core makes; events only from the core; four game
  controllers connected from the start; sound queued, never played; a
  performance counter that counts frames. Ikemen GO's source keeps its SDL
  code; the native reference uses the same stand-in.
- **The disk.** go-patches/common/0001 puts a hook in `syscall.Syscall` and
  `Syscall6`, through which every file call of a Go program passes. The
  core's `chimera_fs.go` answers every call that names a path or one of its
  own descriptors: the game's zip, read through the descriptor Chimera
  mounted (an entry is unpacked when opened, never the whole zip); the
  engine's own data/, external/ and font/, carried in the core, where the
  game has no file of that name; what the game writes, kept in memory and so
  in savestates. Names are found whatever their case (most M.U.G.E.N content
  was made on Windows); a listing is sorted. No file of the computer is ever
  read by the game, in either build. getrandom is answered from a fixed
  stream there too.
- **The clock.** go-patches/common/0003: `time.Now` reads the machine's
  clock in both builds - the Starting Clock setting (2000-01-01 by default),
  then 1/60 s a frame, standing still within a frame. The runtime's own
  clock (timers, sleeps, the scheduler) is not this one: in the sandbox it is
  the sandbox's virtual clock, which FrameAdvance moves by a frame.
- **Random numbers.** Ikemen GO's generator (Lua's math.random too) is
  seeded from `time.Now` as the program starts; the core seeds it again from
  the Starting Clock once the setting is read. Go's own seed (map order,
  select) is one constant in both builds (go-patches/common/0002).
- **Controls.** Four players, each a game controller in Ikemen GO's default
  layout ([Joystick_Pn] of its defaultConfig.ini, which the core writes over
  the game's: a game's config cannot move them), and Escape. A change of a
  button is an SDL event pushed after the frame's end; Ikemen GO polls them
  after the swap, so a press set for frame n reaches the menus at n + 2, the
  same in every run.
- **What the core sets in the game's configuration** (chimera_core.go,
  chimeraConfig): OpenGL 3.3; the picture is the game's own resolution
  (GameWidth x GameHeight, at most 1920x1080); no fullscreen, no vsync, no
  multisampling (it multiplies a software renderer's work); 44100 Hz sound;
  the music read as it plays (no RAM-buffer goroutine); no loading beside the
  frames (BootLoadingMode 0, VsScreenLoading and TurnsLoading off).

## Patches to Ikemen GO

- 0001: util_desktop.go (message boxes through GTK, the computer's fonts,
  the Vulkan renderer's choice) is not in the core's build; go/chimera's
  `chimera_util.go` gives the same functions: an error ends the machine with
  its text, fonts are the game's or the engine's, one renderer.
- 0002: the core sets its part of the configuration after it is read.
- 0003: the core mixes the sound at each frame's end, from Ikemen GO's mixer,
  exactly a frame's share of 44100 Hz; the goroutine that pushed sound to SDL
  every 17 ms is not started.
- 0004: frames are paced by the core, not the computer's clock: every frame
  is drawn, none skipped to catch up.
- 0005: module music (libxmp) is read through the core's disk and given to
  libxmp from memory; libxmp's own loader would open the computer's file.
- 0006: loading ends before the next frame. Ikemen GO loads a match on a
  goroutine while the main loop draws frames; how far it got by a given frame
  depended on the computer's speed (70 frames natively, 5 in the sandbox,
  measured). The loader still runs on its goroutine; the main thread runs
  the OpenGL work it queues, in the order it queues it, and waits for the
  end. Its order is the loader's, so both builds upload the same textures in
  the same order.
- 0007: background videos are decoded on the frame (see "Background
  videos").
- 0008: the music player's choice of decoder is one function, bgmDecode,
  which gives a file none of Ikemen GO's decoders reads to the core's FFmpeg
  (see "Older games and every media file").
- patches/go-mp3/0001, to the MP3 decoder (a Go module): a frame header it
  cannot decode is looked past instead of failing the file.

## The game's properties (2026-10-20)

A game core names its state (Chimera's docs/game-cores.md). Ikemen GO's is on
Go's heap, so the core keeps a block of its own, the "Game State" domain
(chimera_props.c, chimera_props.go): 32 bytes for the match (the frame, the
random seed, the round, the round's time left, the match time, each side's
wins, the round state) and 64 for each of the eight root fighters (life and
its most, power and its most, position, velocity, state and animation
numbers, guard and dizzy points, red life, facing, present). After every
frame the core copies Ikemen GO's values in; before the next, whatever a tool
changed is written back - the writable ones only (life, power, position,
velocity, guard and dizzy points, red life, the random seed, the round's
time). A poke is therefore applied when the next frame begins, and a freeze is
the same write before every frame, as on a machine's RAM. The table names the
fighters Player.Life[1] to [8], player 1 first (Ikemen GO's slots: odd
numbers on player 1's side).

## Not done, and why

- **Netplay and rollback** need sockets; the sandbox has none.
- **A bad memory access is not a panic in the sandbox.** Go turns a nil
  pointer dereference into a panic with a signal, and Ikemen GO turns a panic
  into an error message (here: the machine ends with its text). The sandbox
  delivers no signals, so there the same fault ends the machine as a crash,
  without the message. Seen once (2026-10-20), on a bug of the core's own
  that read the round state before the fight screen existed: natively
  "Engine error", in the sandbox a crash. A working game never faults; a
  game that does is stopped either way, only with less said.
- **The GPU.** The bridge would make it fast, but it gives the renderer a
  new OpenGL context at every savestate load, and Ikemen GO's renderer would
  have to rebuild its textures from the machine's memory: the owner's call.

## Measured (2026-10-20)

- Speed: on llvmpipe, 82% of the time is in the code llvmpipe generates for
  shaders (perf). At 1280x720 the screenpack's menus run at about 7 frames a
  second natively, and a frame with nothing drawn costs about 42 ms (five
  full clears and a full copy: two of the clears, of post-processing buffers
  unused without an extra shader, could go).
- A state of the screenpack game is about 610 MB: the 720p motif's pictures,
  decoded by Go (about 230 MB live on its heap) and held again by Mesa as
  textures.
- waterbox/run-gate.sh: 31 passed, 0 failed, in 12.5 minutes. Every new
  test was broken on purpose once: the clock frozen, player 1's A and B
  swapped, turbo ignored and Export Save Data emptied, all at once, failed
  exactly the clock, controls, turbo and save data tests (27 passed, 4
  failed); the teeth test is the comparison's own control.
- tests/run-frontend.sh against Chimera a11b398: 6 ok, 0 failed. chimera-run
  from a movie file and from a project, and Chimera's window under Mono on
  Xvfb, draw the native reference's title menu at frame 459 to the pixel; in
  a fight (frame 1920) the properties read player 1's life 1000 of 1000, and
  setting it to 123 and player 2's power to 2500 reads back a frame later;
  Life Max refuses a write. With the write back switched off, that test
  failed (the life stayed 1000).
- Chimera's contract tests on the package: 22 passed (21 with one binding
  broken on purpose, which the failing test named).
- Windows: the package in the published Windows build of Chimera
  (Development build d498b8bb), headless with a configuration of its own:
  the title menu at frame 459 and the fight at frame 1929 are the Linux
  native reference's pictures to the pixel, and the properties test gives
  the same answers (life 123, power 2500, Life Max not writable). 460 frames
  took 57 s.
- A state of the probe (no motif loaded) is 32 MB; of the screenpack game,
  643 MB.


## Background videos (user-decided, 2026-10-21)

The owner asked for FFmpeg so that background videos play. Ikemen GO plays
WebM videos (storyboards, stages and the screenpack's logo) through reisen, a
Go binding of FFmpeg. Until now the core put a stand-in in its place that
refused every video.

- **What is built.** `waterbox/build-ffmpeg.sh` builds what Ikemen GO's own
  releases build (its build/build.sh): FFmpeg 7.1 (the 7.1.5 release, its
  tarball checked against FFmpeg's signature once and pinned by SHA-256)
  under the LGPL, reading Matroska/WebM, decoding VP8 and VP9 through libvpx
  1.15.2 (only libvpx's decoders read a WebM video's transparency, which the
  screenpack's logo has) and Opus and Vorbis sound, with the scale, pad,
  crop and format filters. reisen is Ikemen GO's own, at the version its
  go.mod names.
- **The same bytes on every computer.** Both libraries are built as plain C
  (FFmpeg `--disable-asm`, libvpx's generic C target) and without threads.
  Which hand-written code a library picks depends on the processor, and
  where that code computes in floats (the Opus and Vorbis decoders, the
  picture scaler) it does not round as the C does. VP8 and VP9 pictures are
  defined to the bit, so libvpx's assembly would be safe in principle; it is
  left out all the same, as in the rpcs3 and ppsspp cores. The native build
  computes FFmpeg's maths with the sandbox's own math functions, as it does
  for everything else (make-native-libm.sh). FFmpeg reads the computer's
  clock in two places only, neither reached here: packet times taken from
  the clock (an option left off) and an expression function `time` (no
  filter Ikemen GO builds uses it).
- **Decoded on the frame (patches/0007, go/chimera/chimera_video.go).**
  Ikemen GO decodes a video on a goroutine that sleeps until each picture is
  due and hands it over; the frame shows whatever has arrived by then. That
  depends on the computer's speed, so the core decodes instead in the
  frame's own call (Tick): every picture due by the machine's clock, and the
  sound packets that come with them, and shows the last one due. A picture
  is due from half a frame before its time, so a 60-picture video on a 60
  frame game shows one picture each frame although WebM rounds its times to
  milliseconds. A video ends, or starts again when it loops, when its last
  picture's time is over (last picture's time plus one picture's length);
  Ikemen GO's goroutine starts the loop again when it reads the end of the
  file, which in a frame-driven decoder would drop the last picture of each
  loop (seen: a 240-picture logo repeating every 239 frames). Packets of a
  stream the video did not open are skipped (Ikemen GO's goroutine would
  hand them to a decoder that is not there).
- **The test video.** The screenpack's credits video carries a sound track
  that is silent all through (its music is a separate MP3), so the video
  probe plays a video of this repository's own, tests/video/beeps.webm
  (made by tests/make-beeps-video.sh): white pictures and a beep at 1 and at
  2 seconds, under the screenpack's logo video looping.
- **Licence.** FFmpeg is LGPL 2.1 and is linked in statically. The LGPL
  allows that when the user can link the program again with a changed
  library: the core's whole source and its scripts are published, and the
  FFmpeg source is the unmodified release, so `build-ffmpeg.sh` with another
  FFmpeg and `link-core.sh` make that core. The package carries FFmpeg's
  LGPL text, libvpx's BSD licence and its patent grant.

Measured (2026-10-21):

- waterbox/run-gate.sh: 38 passed, 0 failed, in 14 minutes. New: the
  screenpack game's run now includes its logo video (and the save and load
  before each of its first 300 frames covers the video's decoder); the video
  probe's pictures and sound native = sandbox over 300 frames, saved at frame
  90 and loaded in a new host, saved and loaded before each of its first 130
  frames; its white pictures on frames 59-64 and 119-124 and its beeps
  starting on frames 59 and 119; the looping logo showing frame 20's picture
  again at frame 260; frame 60 of the screenpack game showing the logo (15%
  of its pixels lit; black without the video).
- The new tests broken on purpose, twice. Videos one frame late and a loop
  restarting from when the decoder got there: the pictures, sound and loop
  tests failed (white on 60-65, beeps from 60 and 120, frame 260 not frame
  20's), the rest passed. Ikemen GO's own decoding on a goroutine: native and
  sandbox differed and the pictures, sound and loop tests failed.
- tests/run-frontend.sh against Chimera a11b398: 6 ok, 0 failed, with the
  new package. Chimera's contract tests on it: 22 passed.
- Windows (the published Chimera, Development build d498b8bb, headless): the
  screenpack game's frame 60 (the logo video), and the video probe's frames
  62 (a white picture under the logo) and 260 (the logo after one loop) are
  the Linux native build's pictures to the pixel. The sound was not compared
  there.
- Cost: the video probe's 300 frames take 12.3 s natively with its two
  videos and 4.5 s without, about 26 ms a frame for a 1280x720 VP9 video
  with transparency decoded in plain C, against the 100 to 140 ms a 720p
  frame of the screenpack costs on llvmpipe.
- States grow while a video plays: the screenpack game's state at frame 300,
  just after its logo, is 851 MB (644 MB before FFmpeg); in the fight, at
  frame 2000, 604 MB. Each decoded picture is a new 3.7 MB block of Go's
  heap, so the heap grows until Go collects it. The video probe's state is
  96 MB.
- The package is 38.1 MB (37.0 MB before).

## Older games and every media file (user-decided, 2026-10-21)

The owner gave a game to try, KOF Special, a fan-made King of Fighters game
for Ikemen GO (1.2 GB, 300 characters; commercial characters, so it stays
outside this repository and its tests skip without it), and asked that
"besides working correctly, all media files in that game must play correctly
before we publish the core".

- **The game was made for Ikemen GO v0.99.0** (October 2023), and its folder
  carries v0.99.0's own scripts and common files unchanged (only line ends
  differ). The v1.0 engine cannot run them (`main.lua:56: attempt to call a
  non-function object`). The owner chose (from: this, a separate v0.99 core,
  both) to run such games on v1.0, as Ikemen GO's own advice for upgrading a
  game says: put the new release's files over the old ones.
- **How the core recognizes an older game (chimera_legacy.go).** Its
  `external/script/main.lua` is one of the versions Ikemen GO had before
  v1.0.0. `waterbox/make-legacy-list.py` lists, from extern/Ikemen-GO's
  history, every older version of the engine's own files a game folder
  carries (external/script, external/shaders, data/*.zss, data/common.*):
  1784 versions of 44 files, hashed without carriage returns. Of such a game,
  every file that is one of them is set aside, so the core's own v1.0 file
  takes its place; nothing else of the game is touched. A script the game's
  author changed is no known version and stays (and then likely stops the
  engine, which says where).
- **Its modules.** Ikemen GO's modules (external/mods) are Lua the engine
  loads by itself at start; the 2023 versions the game carries stop v1.0
  (`bossrush.lua:141: attempt to index a non-table object`). Ikemen GO's
  modules repository has current versions of Boss Rush, Score Challenge,
  Time Challenge and VS 100 Kumite (extern/Ikemen-GO-modules, MIT), which
  take their place in an older game; Rank, which that repository removed in
  December 2025, is left out. KOF Special's screenpack never turns Rank on
  (no [Rank Info]), so it did nothing under v0.99 either.
- **Its settings.** v0.99 kept them in save/config.json, v1.0 in
  save/config.ini. The core writes the config.ini from v0.99's defaults with
  the game's config.json over them: the game's size (v0.99's default is
  640x480, v1.0's 1280x720), its motif, difficulty, rounds, life, team and
  debug settings and the rest that v1.0 still has. Not carried: what is the
  core's own (picture, sound rate, controls), the window, networking, and
  Ratio (a module in v1.0; KOF Special does not name it). v0.99 picks one of
  its external shaders by number; v1.0 uses every one it lists, so only the
  picked one is listed. The common files are v1.0's, with whatever the game
  added to v0.99's list.
- **The common effects.** v1.0's default settings load `data/gofx/gofx.def`
  (dizzy birds, guard break and tag effects), and v1.0's own dizzy.zss names
  them: without them a match does not start (`anim: Invalid data: go`).
  Ikemen GO's releases take them from the screenpack, so a game made for
  v0.99 does not have them (it has v0.99's smaller set in data/, which its
  configuration never loaded). The core carries the screenpack's data/gofx
  as one of the engine's files (CC BY 3.0, by Shiyo Kakuge).
- **The media check (tests/media).** A test build of the core (never the
  package) pulls every music file and every sound of a game's folder
  through the engine's own playback: the decoder Bgm.Open picks, the SND
  reader, the looper and the resampler to 44100 Hz, as fast as it goes. It
  prints, for each, its length, a SHA-1 of the sound and its loudness frame
  by frame; `check-media.py` compares that between the native build and the
  sandbox (bit for bit) and with ffmpeg's decoding of the same file (the
  length, and the loudness frame by frame). What does not agree is looked at
  again with ffmpeg's decoding resampled the engine's way: Ikemen GO's
  default resampling (quality 1) draws a straight line between two
  samples, which dulls the top of a sound recorded at a low rate.
- **What it found in KOF Special, and what was done.**
  - `sound/14 Kusanagi Kyo.mp3` did not play at all: a kilobyte of junk
    after its last frame holds four bytes that look like a free-bitrate
    frame header, which go-mp3 (Ikemen GO's MP3 decoder) refuses for the
    whole file; further on, one that looks like a layer 2 header. A patch to
    go-mp3 (patches/go-mp3, built in its place by build-ikemen.sh) looks
    past a header it cannot decode, as past any other bytes that are not a
    header; the file plays to its end, 193.4 s, as ffmpeg plays it. The
    stage that names it is not in the game's select list.
  - `data/XIend.mpc` is Musepack, which none of Ikemen GO's decoders reads.
    Patch 0008 gathers Bgm.Open's choice of decoder in one function and
    gives a file none of them reads to the core's FFmpeg (chimera_music.c
    and .go: decoded whole as it opens, kept as 16-bit samples the player
    loops and seeks); build-ffmpeg.sh adds FFmpeg's Musepack reader and
    decoders. No file of the game names XIend.def. The decoding is the
    core's own C, not reisen's: reisen sends a packet and takes one frame,
    and a Musepack 8 packet holds several, so the next packet was refused
    ("couldn't send the packet to the codec context", seen first in CI,
    whose mpcenc makes Musepack 8; the game's file is Musepack 7).
  - 89 sounds in the characters' SND files are one 110-byte placeholder: a
    valid WAV of a 3 ms click, which MUGEN plays and Ikemen GO (v0.99 and
    v1.0 alike) leaves out, as it leaves out every sound under 128 bytes.
    The owner chose to keep Ikemen GO's rule; the check notes them.
  - `chars/hwajai/snd/f_10_voice/f_10_voice_bnk-0000000027.mp3` is an empty
    file: it holds no sound to play.
- **One more trap**: the media check runs in one go inside the core's start,
  and the sandbox's one thread never gave Go's collector its turn, so the
  memory of every file stayed taken (out of memory at 5.1 GB, 90% through,
  while natively 13 MB stayed live). A game's frame ends and lets the
  collector run; the check collects after each file.

Measured (2026-10-21):

- waterbox/run-gate.sh, with IKEMEN_KOF_ZIP naming a copy of KOF Special
  and mpcenc on the path (from Ubuntu's musepack-tools, unpacked, not
  installed): 53 passed, 0 failed, 0 skipped, in 26 minutes. New: older games (6 tests), media (4), kof
  special (4, and its media). The comparison of two runs now also asks
  that both ran to their last frame: two runs that both stopped at the
  start compare the same and prove nothing.
- Broken on purpose, three ways in one run (44 passed, 8 failed): the
  recognition turned off, the go-mp3 patch reduced to a comment, and FFmpeg
  refusing every music file. Failed: the four older-game tests that look for
  what the core did and its config.ini, the media test game (junk-end.mp3:
  "free bitrate format is not supported") and the junk test, KOF Special's
  media (XIend.mpc and the Kusanagi Kyo MP3) and its recognition. Its Arcade
  comparison and its savestate passed because both runs had stopped at the
  start (on v0.99's shader, which v1.0 cannot compile): hence the stricter
  comparison above.
- KOF Special, besides the gate: Arcade into the second round, 9000 frames,
  native = sandbox, and saved at frame 5000 = straight (a state is 421 MB);
  Watch Mode for 30000 frames (a whole match between two computer players,
  then the select screen), native = sandbox, the sandbox's process at most
  2.6 GB (natively 0.56 GB); Boss Rush (the replaced module) to its first
  fight, against its boss, natively. Then VS Mode (each player picks with
  their own controller, both attack, into the second round, 6000 frames),
  Training (the infinite timer and full gauges, 3000 frames) and Survival
  (a loss, Game Over, and a new run as a team of two, 6000 frames): each
  native = sandbox. The game runs at about 29 frames a second at 640x480
  in the sandbox.
- The media check of KOF Special: 329 music files (about 6.3 hours) and
  13,447 sounds in 3.4 minutes natively and 3.3 in the sandbox; every one the
  same in both, bit for bit, and as ffmpeg decodes it (18 of the sounds once
  ffmpeg's decoding is resampled the engine's way), except what the owner
  kept out and the empty file.
- tests/run-frontend.sh against Chimera a11b398: 6 ok, 0 failed. Chimera's
  contract tests on the package: 22 passed.
- Windows (the published Chimera, Development build d498b8bb, headless): KOF
  Special's Arcade, the gate's inputs, at frames 1600 (the fight starting)
  and 4000 (in the first round) is the Linux native build's picture to the
  pixel. The sound was not compared there.
- The package is 38.6 MB (38.1 MB before).
