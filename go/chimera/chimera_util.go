//go:build chimera

// What util_desktop.go gives a desktop build, for the Chimera core (patch
// 0001 leaves util_desktop.go out of it): no message boxes - an error ends
// the machine with its text, which Chimera shows - no fonts of the computer,
// and one renderer, OpenGL 3.3, drawn on the core's own Mesa.
package main

import (
	"fmt"
	"io"
	"os"
)

func NewLogWriter() io.Writer {
	return os.Stderr
}

func ShowInfoDialog(message, title string) {
	fmt.Fprintf(os.Stderr, "%s: %s\n", title, message)
}

// ShowErrorDialog: Ikemen GO stops after an error dialog, so the machine
// does too, with the error as its reason.
func ShowErrorDialog(message string) {
	fmt.Fprintf(os.Stderr, "I.K.E.M.E.N Error: %s\n", message)
	chimeraFail("Ikemen GO: " + message)
}

// LoadFntTtf is util_desktop.go's, without the search of the computer's own
// fonts: a font is the game's, or the engine's (font/).
func LoadFntTtf(f *Fnt, fontfile string, filename string, height int32) {
	fileDir := SearchFile(filename, []string{fontfile, sys.motif.Def, "", "data/"}, "font/")
	if fp := FileExist(fileDir); len(fp) == 0 {
		panic(fmt.Errorf("failed to find ttf font %v (the core uses no font of the computer's)", fileDir))
	}
	if height == -1 {
		height = int32(f.Size[1])
	} else {
		f.Size[1] = uint16(height)
	}
	ttf, err := gfxFont.LoadFont(fileDir, height, int(sys.gameWidth), int(sys.gameHeight))
	if err != nil {
		panic(fmt.Errorf("failed to load ttf font %v: %w", fileDir, err))
	}
	f.ttf = ttf.(Font)
	f.palettes = make([][256]uint32, 1)
	for i := 0; i < 256; i++ {
		f.palettes[0][i] = 0
	}
}

func selectRenderer(cfgVal string) (Renderer, FontRenderer) {
	return &Renderer_GL33{}, &FontRenderer_GL33{}
}

func Logcat(s string) {
	fmt.Println(s)
}
