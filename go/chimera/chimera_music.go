//go:build chimera

// Music in a format none of Ikemen GO's decoders reads (patch 0008), decoded
// by the core's FFmpeg, which reads Musepack besides the videos' formats
// (build-ffmpeg.sh). The whole file is decoded as it is opened
// (chimera_music.c) and kept as 16-bit samples, which the music player loops
// and seeks like any other music.
package main

/*
#cgo pkg-config: libavformat libavcodec libswresample libavutil
#include "chimera_music.h"
#include <stdlib.h>
*/
import "C"

import (
	"errors"
	"io"
	"unsafe"

	"github.com/gopxl/beep/v2"
)

type chimeraPCM struct {
	samples [][2]int16
	pos     int
}

func (p *chimeraPCM) Stream(out [][2]float64) (int, bool) {
	n := len(p.samples) - p.pos
	if n > len(out) {
		n = len(out)
	}
	for i := 0; i < n; i++ {
		s := p.samples[p.pos+i]
		out[i] = [2]float64{float64(s[0]) / 32768, float64(s[1]) / 32768}
	}
	p.pos += n
	return n, n > 0
}

func (p *chimeraPCM) Err() error    { return nil }
func (p *chimeraPCM) Len() int      { return len(p.samples) }
func (p *chimeraPCM) Position() int { return p.pos }
func (p *chimeraPCM) Close() error  { return nil }

func (p *chimeraPCM) Seek(pos int) error {
	if pos < 0 || pos > len(p.samples) {
		return errors.New("seek out of range")
	}
	p.pos = pos
	return nil
}

func chimeraMusic(f io.ReadSeekCloser) (beep.StreamSeekCloser, beep.Format, error) {
	data, err := io.ReadAll(f)
	f.Close()
	if err != nil {
		return nil, beep.Format{}, err
	}
	if len(data) == 0 {
		return nil, beep.Format{}, errors.New("the file is empty")
	}
	cdata := C.CBytes(data)
	defer C.free(cdata)
	var m C.struct_chimera_music
	if C.chimera_music_decode(cdata, C.long(len(data)), &m) != 0 {
		return nil, beep.Format{}, errors.New(C.GoString(&m.error[0]))
	}
	defer C.chimera_music_free(&m)
	frames, channels := int(m.frames), int(m.channels)
	raw := unsafe.Slice((*int16)(unsafe.Pointer(m.samples)), frames*channels)
	pcm := make([][2]int16, frames)
	for i := range pcm {
		if channels == 1 {
			// a mono file at full level on both sides, as Ikemen GO's own
			// decoders play it
			pcm[i] = [2]int16{raw[i], raw[i]}
		} else {
			pcm[i] = [2]int16{raw[2*i], raw[2*i+1]}
		}
	}
	return &chimeraPCM{samples: pcm}, beep.Format{SampleRate: beep.SampleRate(m.rate), NumChannels: 2, Precision: 2}, nil
}
