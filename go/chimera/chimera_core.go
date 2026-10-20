//go:build chimera

// The Go half of the glue between Chimera's calls (chimera_core.c) and
// Ikemen GO, which this core builds as a C archive with the "chimera" tag.
//
// At start (a package init, while the C library starts) a goroutine locked
// to a thread of its own waits for Init, opens the game, connects the
// players' controllers and runs Ikemen GO's main. Every swap of the window's
// buffers (the stand-in sdl package's GLSwap) is a frame's end: frameEnd mixes
// the frame's sound, gives it and the picture to the C half, waits there for
// the next frame, and turns the controls Chimera set into the events Ikemen
// GO polls.
package main

/*
#cgo CFLAGS: -DCHIMERA_CORE
#include "chimera_core.h"
#include <stdlib.h>
*/
import "C"

import (
	"fmt"
	"os"
	"runtime"
	"runtime/debug"
	"unsafe"

	"github.com/veandco/go-sdl2/sdl"
)

// chimeraCore is true in this build: what Ikemen GO's patched files ask.
const chimeraCore = true

var chimera struct {
	fps     int
	frame   uint64 // the frame being made
	sent    [C.CHIMERA_BUTTONS]uint8
	buttons [C.CHIMERA_BUTTONS]uint8
	axes    [C.CHIMERA_AXES]int32
	mix     [][2]float64
	sound   []int16
	saveGen uint64 // the file changes the last published save data had
}

func init() {
	runtime.GOMAXPROCS(1)
	os.Args = []string{"Ikemen_GO"}
	sdl.Controllers = C.CHIMERA_PLAYERS
	sdl.Hooks.MakeContext = func(w, h int) error {
		if r := C.chimera_gl_make(C.int(w), C.int(h)); r != 0 {
			return fmt.Errorf("the core could not make an OpenGL 3.3 context of %dx%d (%d)", w, h, int(r))
		}
		return nil
	}
	sdl.Hooks.Size = func() (int, int) {
		return int(C.chimera_gl_width()), int(C.chimera_gl_height())
	}
	sdl.Hooks.Clock = func() uint64 {
		return chimera.frame * 1000000000 / uint64(chimera.fps)
	}
	sdl.Hooks.Swap = frameEnd
	go chimeraMain()
}

// chimeraFail ends the machine with a reason: Init answers it, or the frame
// that was running never ends.
func chimeraFail(why string) {
	cs := C.CString(why)
	C.chimera_failed(cs) // does not return
}

func chimeraMain() {
	runtime.LockOSThread()
	chimera.fps = int(C.chimera_wait_start())
	if chimera.fps < 1 {
		chimera.fps = 60
	}
	defer func() {
		if r := recover(); r != nil {
			chimeraFail(fmt.Sprintf("Ikemen GO stopped: %v\n%s", r, debug.Stack()))
		}
	}()

	var name [1024]C.char
	if C.chimera_slot(C.CString("game"), 0, &name[0], C.int(len(name))) == 0 {
		chimeraFail("the project has no game: give the zip of an Ikemen GO game folder")
	}
	if err := fsStart(C.GoString(&name[0])); err != nil {
		chimeraFail(fmt.Sprintf("the game's zip (%s) could not be read: %v", C.GoString(&name[0]), err))
	}

	// the players' controllers are connected from the start
	for i := 0; i < C.CHIMERA_PLAYERS; i++ {
		sdl.Push(sdl.JoyDeviceAddedEvent{Type: sdl.JOYDEVICEADDED, Which: sdl.JoystickID(i)})
	}
	realMain()
	chimeraFail("the game ended (Exit was chosen)")
}

// the share of a second's sound one frame holds: rate / fps, the remainder
// carried, so that a second holds the whole rate
func soundFrames(frame uint64) int {
	r, f := uint64(C.CHIMERA_RATE), uint64(chimera.fps)
	return int((frame+1)*r/f - frame*r/f)
}

func frameEnd() {
	n := soundFrames(chimera.frame)
	if len(chimera.mix) < n {
		chimera.mix = make([][2]float64, n)
		chimera.sound = make([]int16, 2*n)
	}
	got := 0
	if sp, ok := speaker.(*SDLSpeaker); ok && sp.mixer != nil {
		sp.mu.Lock()
		got, _ = sp.mixer.Stream(chimera.mix[:n])
		sp.mu.Unlock()
	}
	for i := 0; i < n; i++ {
		l, r := 0.0, 0.0
		if i < got {
			l, r = chimera.mix[i][0], chimera.mix[i][1]
		}
		chimera.sound[2*i] = floatToS16(l)
		chimera.sound[2*i+1] = floatToS16(r)
	}
	if g := fsGeneration(); g != chimera.saveGen {
		chimera.saveGen = g
		publishSaveData()
	}
	next := C.chimera_frame_end((*C.int16_t)(unsafe.Pointer(&chimera.sound[0])), C.int(n))
	chimera.frame = uint64(next)

	C.chimera_inputs((*C.uint8_t)(unsafe.Pointer(&chimera.buttons[0])), (*C.int32_t)(unsafe.Pointer(&chimera.axes[0])))
	sendControls()
}

// a player's buttons, in waterbox.config's order, as Ikemen GO's default
// controller layout has them ([Joystick_Pn] in its defaultConfig.ini)
type padControl struct {
	button  sdl.GameControllerButton
	trigger sdl.GameControllerAxis // a button that is a trigger, when >= 0
}

var padControls = [C.CHIMERA_PLAYER_BUTTONS]padControl{
	{sdl.CONTROLLER_BUTTON_DPAD_UP, -1},
	{sdl.CONTROLLER_BUTTON_DPAD_DOWN, -1},
	{sdl.CONTROLLER_BUTTON_DPAD_LEFT, -1},
	{sdl.CONTROLLER_BUTTON_DPAD_RIGHT, -1},
	{sdl.CONTROLLER_BUTTON_A, -1},                          // a
	{sdl.CONTROLLER_BUTTON_B, -1},                          // b
	{sdl.CONTROLLER_BUTTON_INVALID, sdl.CONTROLLER_AXIS_TRIGGERRIGHT}, // c = RT
	{sdl.CONTROLLER_BUTTON_X, -1},                          // x
	{sdl.CONTROLLER_BUTTON_Y, -1},                          // y
	{sdl.CONTROLLER_BUTTON_RIGHTSHOULDER, -1},              // z = RB
	{sdl.CONTROLLER_BUTTON_START, -1},                      // start
	{sdl.CONTROLLER_BUTTON_LEFTSHOULDER, -1},               // d = LB
	{sdl.CONTROLLER_BUTTON_INVALID, sdl.CONTROLLER_AXIS_TRIGGERLEFT}, // w = LT
	{sdl.CONTROLLER_BUTTON_BACK, -1},                       // menu
}

// the [Joystick_Pn] layout that matches padControls
func chimeraPadConfig(player int) *KeysProperties {
	return &KeysProperties{
		Joystick: player - 1,
		Up:       "DP_U", Down: "DP_D", Left: "DP_L", Right: "DP_R",
		A: "A", B: "B", C: "RT", X: "X", Y: "Y", Z: "RB",
		Start: "START", D: "LB", W: "LT", Menu: "BACK",
	}
}

// sendControls turns what changed since the last frame into events, the
// players in order, then Escape.
func sendControls() {
	for p := 0; p < C.CHIMERA_PLAYERS; p++ {
		for b := 0; b < C.CHIMERA_PLAYER_BUTTONS; b++ {
			i := p*C.CHIMERA_PLAYER_BUTTONS + b
			if chimera.buttons[i] == chimera.sent[i] {
				continue
			}
			chimera.sent[i] = chimera.buttons[i]
			pc := padControls[b]
			if pc.trigger >= 0 {
				v := int16(0)
				if chimera.buttons[i] != 0 {
					v = 32767
				}
				sdl.Push(sdl.ControllerAxisEvent{Type: sdl.CONTROLLERAXISMOTION, Which: sdl.JoystickID(p), Axis: pc.trigger, Value: v})
			} else {
				state, typ := sdl.RELEASED, sdl.CONTROLLERBUTTONUP
				if chimera.buttons[i] != 0 {
					state, typ = sdl.PRESSED, sdl.CONTROLLERBUTTONDOWN
				}
				sdl.Push(sdl.ControllerButtonEvent{Type: typ, Which: sdl.JoystickID(p), Button: pc.button, State: state})
			}
		}
	}
	esc := C.CHIMERA_PLAYERS * C.CHIMERA_PLAYER_BUTTONS
	if chimera.buttons[esc] != chimera.sent[esc] {
		chimera.sent[esc] = chimera.buttons[esc]
		state, typ := sdl.RELEASED, sdl.KEYUP
		if chimera.buttons[esc] != 0 {
			state, typ = sdl.PRESSED, sdl.KEYDOWN
		}
		sdl.Push(sdl.KeyboardEvent{Type: typ, State: state, Keysym: sdl.Keysym{Sym: sdl.K_ESCAPE, Scancode: sdl.SCANCODE_ESCAPE}})
	}
}

// chimeraConfig is what the core sets in the game's configuration after it
// is read (patch 0002): the players' controls, and what a machine has to be.
func chimeraConfig(cfg *Config) {
	// one renderer: OpenGL 3.3 on the core's Mesa
	cfg.Video.RenderMode = "OpenGL 3.3"
	// the picture is the game's own size (its "internal resolution")
	cfg.Video.WindowWidth = int(cfg.Video.GameWidth)
	cfg.Video.WindowHeight = int(cfg.Video.GameHeight)
	if cfg.Video.WindowWidth > C.CHIMERA_MAX_W || cfg.Video.WindowHeight > C.CHIMERA_MAX_H {
		cfg.Video.WindowWidth, cfg.Video.WindowHeight = C.CHIMERA_MAX_W, C.CHIMERA_MAX_H
	}
	cfg.Video.Fullscreen = false
	cfg.Video.Borderless = false
	cfg.Video.VSync = 0
	cfg.Video.Framerate = chimera.fps
	// multisampling multiplies the work of a software renderer; off
	cfg.Video.MSAA = 0
	cfg.Video.RendererDebugMode = false
	// the sound Chimera plays
	cfg.Sound.SampleRate = C.CHIMERA_RATE
	// the music is read as it plays, never by a goroutine of its own
	cfg.Sound.BGMRAMBuffer = false
	for p := 1; p <= C.CHIMERA_PLAYERS; p++ {
		key := fmt.Sprintf("Joystick_P%d", p)
		if cfg.Joystick == nil {
			cfg.Joystick = map[string]*KeysProperties{}
		}
		cfg.Joystick[key] = chimeraPadConfig(p)
	}
}

// publishSaveData gives the C half every file the game wrote, copied into
// C's memory, for Emulator > Export Save Data (GetSaveDataFile*).
func publishSaveData() {
	names := savedFiles()
	C.chimera_savedata_begin(C.int(len(names)))
	for i, n := range names {
		b := fileBytes(n)
		cn := C.CString(n)
		var cb unsafe.Pointer
		if len(b) > 0 {
			cb = C.CBytes(b)
		}
		C.chimera_savedata_put(C.int(i), cn, cb, C.longlong(len(b)))
	}
}
