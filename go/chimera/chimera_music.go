//go:build chimera

// Music in a format none of Ikemen GO's decoders reads (patch 0008), decoded
// by the core's FFmpeg, which reads Musepack besides the videos' formats
// (build-ffmpeg.sh). The whole file is decoded as it is opened and kept as
// 16-bit samples, which the music player loops and seeks like any other
// music.
package main

import (
	"encoding/binary"
	"errors"
	"io"
	"math"

	"github.com/gopxl/beep/v2"
	"github.com/ikemen-engine/reisen"
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

func pcm16(v float64) int16 {
	return int16(math.Round(math.Max(-1, math.Min(1, v)) * 32767))
}

func chimeraMusic(f io.ReadSeekCloser) (beep.StreamSeekCloser, beep.Format, error) {
	defer f.Close()
	m, err := reisen.NewMediaFromReader(f)
	if err != nil {
		return nil, beep.Format{}, err
	}
	defer m.Close()
	streams := m.AudioStreams()
	if len(streams) == 0 {
		return nil, beep.Format{}, errors.New("FFmpeg finds no sound in it")
	}
	a := streams[0]
	if err := m.OpenDecode(); err != nil {
		return nil, beep.Format{}, err
	}
	defer m.CloseDecode()
	if err := a.Open(); err != nil {
		return nil, beep.Format{}, err
	}
	defer a.Close()
	var pcm [][2]int16
	for again := 0; again < 1000; {
		packet, got, err := m.ReadPacket()
		if err != nil {
			return nil, beep.Format{}, err
		}
		if !got {
			break
		}
		if packet == nil { // the reader asked to be called again
			again++
			continue
		}
		again = 0
		if packet.StreamIndex() != a.Index() {
			continue
		}
		af, ok, err := a.ReadAudioFrame()
		if err != nil {
			return nil, beep.Format{}, err
		}
		if !ok || af == nil {
			continue
		}
		// two channels of 64-bit floats (reisen's output)
		raw := af.Data()
		for i := 0; i+16 <= len(raw); i += 16 {
			pcm = append(pcm, [2]int16{
				pcm16(math.Float64frombits(binary.LittleEndian.Uint64(raw[i:]))),
				pcm16(math.Float64frombits(binary.LittleEndian.Uint64(raw[i+8:]))),
			})
		}
	}
	if len(pcm) == 0 {
		return nil, beep.Format{}, errors.New("FFmpeg decodes no sound from it")
	}
	return &chimeraPCM{samples: pcm}, beep.Format{SampleRate: beep.SampleRate(a.SampleRate()), NumChannels: 2, Precision: 2}, nil
}
