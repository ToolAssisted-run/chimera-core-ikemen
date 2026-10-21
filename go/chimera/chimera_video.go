//go:build chimera

// Background videos, decoded on the frame (patch 0007). Ikemen GO decodes a
// video on a goroutine that sleeps until each picture is due and hands it
// over; the frame then shows whatever has arrived. In the core the frame
// decodes, in Tick, every picture due by now and the sound that comes with
// it, so what a frame shows depends only on the machine's clock.
package main

import (
	"encoding/binary"
	"image"
	"math"
	"time"

	"github.com/ikemen-engine/reisen"
)

// chimeraDecode decodes up to the picture due now and hands that one to Tick.
func (bgv *bgVideo) chimeraDecode() {
	if bgv.media == nil || bgv.chimeraFinish == nil || !bgv.playing {
		return
	}
	// a picture is due from half a frame before its time, so a video made at
	// the game's rate shows one picture a frame, though its times are rounded
	now := time.Now().Sub(bgv.startWall) + time.Second/time.Duration(2*chimera.fps)
	var show *image.RGBA
	rewound := false
	for {
		if bgv.chimeraHaveNext {
			if bgv.chimeraNextAt > now {
				break
			}
			if bgv.chimeraNext != nil {
				show = bgv.chimeraNext
			}
			bgv.chimeraHaveNext, bgv.chimeraNext = false, nil
			continue
		}
		if bgv.chimeraEndAt == 0 {
			if bgv.chimeraPacket() {
				continue
			}
			// the end of the file: the video ends when its last picture's
			// time is over
			bgv.chimeraEndAt = bgv.elapsedPTS + bgv.chimeraFrameTime()
		}
		if bgv.chimeraEndAt > now {
			break
		}
		end := bgv.chimeraEndAt
		bgv.chimeraEndAt = 0
		if !bgv.loop {
			if show != nil {
				bgv.frameBuffer <- show
			}
			bgv.chimeraFinish()
			return
		}
		// as Ikemen GO's goroutine starts the video again, but from the time
		// the video ended rather than from when the goroutine got there; once
		// a frame, so a video with no picture does not loop forever
		if rewound {
			break
		}
		rewound = true
		if err := bgv.videoStream.Rewind(0); err != nil {
			break
		}
		if bgv.audioStream != nil {
			_ = bgv.audioStream.Rewind(0)
		}
		drainAudio(bgv.audioBuffer)
		drainFrames(bgv.frameBuffer)
		if bgv.videoVol != nil {
			if rs, ok := bgv.videoVol.Streamer.(*reisenAudioStreamer); ok {
				rs.pending = nil
				rs.closed = false
			}
		}
		bgv.haveBasePTS = false
		bgv.elapsedPTS = 0
		bgv.startWall = bgv.startWall.Add(end)
		now -= end
	}
	if show != nil {
		drainFrames(bgv.frameBuffer)
		bgv.frameBuffer <- show
	}
}

// chimeraFrameTime is how long one of the video's pictures lasts.
func (bgv *bgVideo) chimeraFrameTime() time.Duration {
	if num, den := bgv.videoStream.FrameRate(); num > 0 && den > 0 {
		return time.Second * time.Duration(den) / time.Duration(num)
	}
	return time.Second / time.Duration(chimera.fps)
}

// chimeraPacket reads and decodes one packet, as processPacket does, but
// keeps a picture as the next one instead of sleeping until it is due. It
// answers false at the end of the video.
func (bgv *bgVideo) chimeraPacket() bool {
	packet, gotPacket, err := bgv.media.ReadPacket()
	if err != nil || !gotPacket {
		return false
	}
	if packet == nil { // the reader asked to be called again
		return true
	}
	switch {
	case packet.Type() == reisen.StreamVideo && packet.StreamIndex() == bgv.videoStream.Index():
		vf, gotFrame, err := bgv.videoStream.ReadVideoFrame()
		if err != nil || !gotFrame || vf == nil {
			return true
		}
		if off, err := vf.PresentationOffset(); err == nil {
			if !bgv.haveBasePTS {
				bgv.basePTS = off
				bgv.haveBasePTS = true
			}
			bgv.elapsedPTS = off - bgv.basePTS
			if bgv.elapsedPTS < 0 {
				bgv.elapsedPTS = 0
			}
		}
		bgv.chimeraHaveNext, bgv.chimeraNextAt, bgv.chimeraNext = true, bgv.elapsedPTS, nil
		if bgv.visible {
			frame := vf.Image()
			premultiplyVideoFrame(frame)
			bgv.chimeraNext = frame
		}
	case packet.Type() == reisen.StreamAudio && bgv.audioStream != nil && packet.StreamIndex() == bgv.audioStream.Index():
		af, gotFrame, err := bgv.audioStream.ReadAudioFrame()
		if err != nil || !gotFrame || af == nil || !bgv.visible {
			return true
		}
		raw := af.Data()
		if len(raw) < 16 {
			return true
		}
		samples := make([]float64, 0, len(raw)/8)
		for i := 0; i+8 <= len(raw); i += 8 {
			samples = append(samples, math.Float64frombits(binary.LittleEndian.Uint64(raw[i:i+8])))
		}
		select {
		case bgv.audioBuffer <- samples:
		default:
		}
	}
	return true
}
