// Package sdl stands in for github.com/veandco/go-sdl2/sdl in the Chimera
// core: Ikemen GO is built against it in place of SDL 2 (a replace directive
// in its go.mod), in the sandbox and in the native reference alike.
//
// It has what Ikemen GO calls and nothing more, with the same names and
// types, and does what a Chimera machine needs instead of what a desktop
// does:
//
//   - one window, which is the core's picture: its OpenGL context is made and
//     its buffers swapped by the core (Hooks.MakeContext, Hooks.Swap); a swap
//     is the end of a frame;
//   - events only from the core (Push): the controls a frame was given;
//   - game controllers that are the core's players, connected from the start;
//   - sound queued for the core to take (Take), never played;
//   - a performance counter that counts the machine's time (Hooks.Clock), so
//     what is drawn from it is the same in every run.
//
// The constants (consts.go) are SDL 2's values, generated from its headers.
package sdl

import (
	"errors"
	"image"
	"sync"
	"unsafe"
)

// ---- types, as go-sdl2 declares them --------------------------------------

type Keycode int32
type Keymod uint32
type Scancode uint32
type GameControllerButton int32
type GameControllerAxis int32
type JoystickID int32
type AudioDeviceID uint32
type AudioFormat uint16
type WindowFlags uint32
type GLattr uint32
type EventType uint32
type ButtonState uint8
type WindowEventID uint32
type EventStateConstant int
type PixelFormatConstant uint32
type AudioDeviceAllowFlags int
type AudioCallback uintptr
type GLContext uintptr

type Event interface {
	GetType() EventType
	GetTimestamp() uint32
}

type CommonEvent struct {
	Type      EventType
	Timestamp uint32
}

type QuitEvent struct {
	Type      EventType
	Timestamp uint32
}

type Keysym struct {
	Scancode Scancode
	Sym      Keycode
	Mod      Keymod
	unused   uint32
}

type KeyboardEvent struct {
	Type      EventType
	Timestamp uint32
	WindowID  uint32
	State     ButtonState
	Repeat    uint8
	Keysym    Keysym
}

type TextInputEvent struct {
	Type      EventType
	Timestamp uint32
	WindowID  uint32
	Text      string
}

type WindowEvent struct {
	Type      EventType
	Timestamp uint32
	WindowID  uint32
	Event     WindowEventID
	Data1     int32
	Data2     int32
}

type ControllerAxisEvent struct {
	Type      EventType
	Timestamp uint32
	Which     JoystickID
	Axis      GameControllerAxis
	Value     int16
}

type ControllerButtonEvent struct {
	Type      EventType
	Timestamp uint32
	Which     JoystickID
	Button    GameControllerButton
	State     ButtonState
}

type JoyDeviceAddedEvent struct {
	Type      EventType
	Timestamp uint32
	Which     JoystickID
}

type JoyDeviceRemovedEvent struct {
	Type      EventType
	Timestamp uint32
	Which     JoystickID
}

func (e CommonEvent) GetType() EventType             { return e.Type }
func (e CommonEvent) GetTimestamp() uint32           { return e.Timestamp }
func (e QuitEvent) GetType() EventType               { return e.Type }
func (e QuitEvent) GetTimestamp() uint32             { return e.Timestamp }
func (e KeyboardEvent) GetType() EventType           { return e.Type }
func (e KeyboardEvent) GetTimestamp() uint32         { return e.Timestamp }
func (e TextInputEvent) GetType() EventType          { return e.Type }
func (e TextInputEvent) GetTimestamp() uint32        { return e.Timestamp }
func (e TextInputEvent) GetText() string             { return e.Text }
func (e WindowEvent) GetType() EventType             { return e.Type }
func (e WindowEvent) GetTimestamp() uint32           { return e.Timestamp }
func (e ControllerAxisEvent) GetType() EventType     { return e.Type }
func (e ControllerAxisEvent) GetTimestamp() uint32   { return e.Timestamp }
func (e ControllerButtonEvent) GetType() EventType   { return e.Type }
func (e ControllerButtonEvent) GetTimestamp() uint32 { return e.Timestamp }
func (e JoyDeviceAddedEvent) GetType() EventType     { return e.Type }
func (e JoyDeviceAddedEvent) GetTimestamp() uint32   { return e.Timestamp }
func (e JoyDeviceRemovedEvent) GetType() EventType   { return e.Type }
func (e JoyDeviceRemovedEvent) GetTimestamp() uint32 { return e.Timestamp }

type DisplayMode struct {
	Format      uint32
	W           int32
	H           int32
	RefreshRate int32
	DriverData  unsafe.Pointer
}

type AudioSpec struct {
	Freq     int32
	Format   AudioFormat
	Channels uint8
	Silence  uint8
	Samples  uint16
	_        uint16
	Size     uint32
	Callback AudioCallback
	UserData unsafe.Pointer
}

// ---- what the core provides ------------------------------------------------

// Hooks are set by the core before Ikemen GO starts.
var Hooks struct {
	// MakeContext makes the window's OpenGL context, of w x h pixels.
	MakeContext func(w, h int) error
	// Swap ends a frame: the picture is taken and the next frame's controls
	// are pushed (Push) before it returns.
	Swap func()
	// Clock is the machine's time in nanoseconds.
	Clock func() uint64
	// Size is the picture's size (the window's).
	Size func() (int, int)
}

var (
	mu     sync.Mutex
	events []Event
)

// Push queues an event for PollEvent.
func Push(e Event) {
	mu.Lock()
	events = append(events, e)
	mu.Unlock()
}

// ---- initialisation, hints, the clipboard ----------------------------------

func Init(flags uint32) error                     { return nil }
func InitSubSystem(flags uint32) error            { return nil }
func Quit()                                       {}
func SetHint(name, value string) bool             { return true }
func GetClipboardText() (string, error)           { return "", nil }
func GLSetAttribute(attr GLattr, value int) error { return nil }

// GLSetSwapInterval: there is no display to wait for.
func GLSetSwapInterval(interval int) error { return nil }

// ShowCursor: there is no pointer.
func ShowCursor(toggle EventStateConstant) (int, error) { return 0, nil }

// GetDesktopDisplayMode answers with the largest picture the core gives.
func GetDesktopDisplayMode(displayIndex int) (DisplayMode, error) {
	return DisplayMode{W: 1920, H: 1080, RefreshRate: 60}, nil
}

// ---- the clock ---------------------------------------------------------------

func GetPerformanceFrequency() uint64 { return 1000000000 }

func GetPerformanceCounter() uint64 {
	if Hooks.Clock != nil {
		return Hooks.Clock()
	}
	return 0
}

func GetTicks() uint32 { return uint32(GetPerformanceCounter() / 1000000) }

// ---- the window ----------------------------------------------------------------

type Window struct {
	w, h   int32
	madeGL bool
}

var theWindow *Window

func CreateWindow(title string, x, y, w, h int32, flags WindowFlags) (*Window, error) {
	if theWindow != nil {
		return nil, errors.New("sdl: the core has one window")
	}
	theWindow = &Window{w: w, h: h}
	return theWindow, nil
}

func (w *Window) GLCreateContext() (GLContext, error) {
	if Hooks.MakeContext == nil {
		return 0, errors.New("sdl: the core gives no OpenGL")
	}
	if err := Hooks.MakeContext(int(w.w), int(w.h)); err != nil {
		return 0, err
	}
	w.madeGL = true
	return 1, nil
}

func (w *Window) GLMakeCurrent(ctx GLContext) error { return nil }

func (w *Window) GLSwap() {
	if Hooks.Swap != nil {
		Hooks.Swap()
	}
}

func (w *Window) GetSize() (int32, int32) {
	if Hooks.Size != nil && w.madeGL {
		ww, hh := Hooks.Size()
		return int32(ww), int32(hh)
	}
	return w.w, w.h
}

func (w *Window) GLGetDrawableSize() (int32, int32) { return w.GetSize() }
func (w *Window) SetSize(width, height int32)       {}
func (w *Window) SetPosition(x, y int32)            {}
func (w *Window) GetPosition() (int32, int32)       { return 0, 0 }
func (w *Window) SetBordered(bordered bool)         {}
func (w *Window) SetResizable(resizable bool)       {}
func (w *Window) SetFullscreen(flags uint32) error  { return nil }
func (w *Window) SetTitle(title string)             {}
func (w *Window) SetIcon(icon *Surface)             {}
func (w *Window) GetDisplayIndex() (int, error)     { return 0, nil }
func (w *Window) Destroy() error                    { return nil }
func (w *Window) Raise()                            {}
func (w *Window) Show()                             {}
func (w *Window) GetID() (uint32, error)            { return 1, nil }

// ---- surfaces (the window icon) ------------------------------------------------

type Surface struct {
	W, H   int32
	pixels []byte
}

func CreateRGBSurfaceWithFormat(flags uint32, width, height, depth int32, format uint32) (*Surface, error) {
	return &Surface{W: width, H: height, pixels: make([]byte, int(width)*int(height)*int(depth/8))}, nil
}

func (s *Surface) Lock() error    { return nil }
func (s *Surface) Unlock()        {}
func (s *Surface) Free()          {}
func (s *Surface) Pixels() []byte { return s.pixels }

// image is imported for go-sdl2's own image helpers, which Ikemen GO does not use.
var _ image.Image

// ---- events ---------------------------------------------------------------------

func PollEvent() Event {
	mu.Lock()
	defer mu.Unlock()
	if len(events) == 0 {
		return nil
	}
	e := events[0]
	events = events[1:]
	if len(events) == 0 {
		events = nil
	}
	return e
}

// ---- game controllers: the core's players -----------------------------------------

type Joystick struct{ id JoystickID }

func (j *Joystick) InstanceID() JoystickID { return j.id }

type GameController struct {
	index int
	joy   Joystick
	open  bool
}

// Controllers is how many the core connects (the core sets it before start).
var Controllers = 4

var controllers [16]*GameController

func GameControllerOpen(index int) *GameController {
	if index < 0 || index >= Controllers || index >= len(controllers) {
		return nil
	}
	if controllers[index] == nil {
		controllers[index] = &GameController{index: index, joy: Joystick{id: JoystickID(index)}}
	}
	controllers[index].open = true
	return controllers[index]
}

func GameControllerAddMapping(mappingString string) int { return 0 }

func (c *GameController) Attached() bool      { return c != nil && c.open }
func (c *GameController) Name() string        { return "Chimera Controller" }
func (c *GameController) Path() string        { return "" }
func (c *GameController) Product() int        { return 0 }
func (c *GameController) ProductVersion() int { return 0 }
func (c *GameController) Vendor() int         { return 0 }
func (c *GameController) HasRumble() bool     { return false }
func (c *GameController) Joystick() *Joystick { return &c.joy }
func (c *GameController) Close()              { c.open = false }
func (c *GameController) Rumble(lowFrequencyRumble, highFrequencyRumble uint16, durationMS uint32) error {
	return nil
}

// ---- sound: queued for the core to take ---------------------------------------------

var (
	audioMu    sync.Mutex
	audioQueue []byte
	audioSpec  AudioSpec
)

func OpenAudioDevice(device string, isCapture bool, desired, obtained *AudioSpec, allowedChanges AudioDeviceAllowFlags) (AudioDeviceID, error) {
	if desired != nil {
		audioSpec = *desired
		if obtained != nil {
			*obtained = *desired
		}
	}
	return 1, nil
}

func PauseAudioDevice(dev AudioDeviceID, pauseOn bool) {}
func CloseAudioDevice(dev AudioDeviceID)               {}

func ClearQueuedAudio(dev AudioDeviceID) {
	audioMu.Lock()
	audioQueue = audioQueue[:0]
	audioMu.Unlock()
}

func QueueAudio(dev AudioDeviceID, data []byte) error {
	audioMu.Lock()
	audioQueue = append(audioQueue, data...)
	audioMu.Unlock()
	return nil
}

func GetQueuedAudioSize(dev AudioDeviceID) uint32 {
	audioMu.Lock()
	defer audioMu.Unlock()
	return uint32(len(audioQueue))
}

// Take moves up to len(out) queued bytes of sound into out and says how many.
func Take(out []byte) int {
	audioMu.Lock()
	n := copy(out, audioQueue)
	audioQueue = audioQueue[:copy(audioQueue, audioQueue[n:])]
	audioMu.Unlock()
	return n
}
