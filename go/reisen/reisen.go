// Package reisen stands in for github.com/ikemen-engine/reisen (FFmpeg) in
// the Chimera core, which does not build FFmpeg: a background video is
// refused when it is opened (NewMediaFromReader), and Ikemen GO goes on
// without it, as it does with a video it cannot read. The types and methods
// are the ones Ikemen GO's video_ffmpeg.go names; none is reached.
package reisen

import (
	"errors"
	"image"
	"io"
	"time"
)

// ErrNoVideo is the answer to every video.
var ErrNoVideo = errors.New("background videos are not played by the Chimera core")

type LogLevel int

const LogLevelWarning LogLevel = 24

func SetLogLevel(level LogLevel) {}

type StreamType int

const (
	StreamVideo StreamType = 0
	StreamAudio StreamType = 1
)

type Stream interface {
	Index() int
	Type() StreamType
	Duration() (time.Duration, error)
	TimeBase() (int, int)
	FrameRate() (int, int)
	Open() error
	Close() error
	Rewind(t time.Duration) error
	CodecName() string
	CodecLongName() string
	BitRate() int64
	FrameCount() int64
}

type baseStream struct{}

func (baseStream) Index() int                       { return 0 }
func (baseStream) Type() StreamType                 { return StreamVideo }
func (baseStream) Duration() (time.Duration, error) { return 0, ErrNoVideo }
func (baseStream) TimeBase() (int, int)             { return 1, 1 }
func (baseStream) FrameRate() (int, int)            { return 1, 1 }
func (baseStream) Open() error                      { return ErrNoVideo }
func (baseStream) Close() error                     { return nil }
func (baseStream) Rewind(t time.Duration) error     { return ErrNoVideo }
func (baseStream) CodecName() string                { return "" }
func (baseStream) CodecLongName() string            { return "" }
func (baseStream) BitRate() int64                   { return 0 }
func (baseStream) FrameCount() int64                { return 0 }

type VideoStream struct{ baseStream }

func (*VideoStream) Width() int                               { return 0 }
func (*VideoStream) Height() int                              { return 0 }
func (*VideoStream) ApplyVideoFilterGraph(graph string) error { return ErrNoVideo }
func (*VideoStream) ReadVideoFrame() (*VideoFrame, bool, error) {
	return nil, false, ErrNoVideo
}

type AudioStream struct{ baseStream }

func (*AudioStream) SampleRate() int   { return 0 }
func (*AudioStream) ChannelCount() int { return 0 }
func (*AudioStream) ReadAudioFrame() (*AudioFrame, bool, error) {
	return nil, false, ErrNoVideo
}

type frame struct{}

func (frame) Data() []byte                               { return nil }
func (frame) PresentationOffset() (time.Duration, error) { return 0, ErrNoVideo }

type VideoFrame struct{ frame }

func (*VideoFrame) Image() *image.RGBA { return nil }

type AudioFrame struct{ frame }

type Packet struct{}

func (*Packet) Type() StreamType { return StreamVideo }
func (*Packet) StreamIndex() int { return 0 }
func (*Packet) Data() []byte     { return nil }

type Media struct{}

func NewMediaFromReader(r io.ReadSeeker) (*Media, error) { return nil, ErrNoVideo }

func (*Media) Close()                           {}
func (*Media) OpenDecode() error                { return ErrNoVideo }
func (*Media) CloseDecode() error               { return nil }
func (*Media) VideoStreams() []*VideoStream     { return nil }
func (*Media) AudioStreams() []*AudioStream     { return nil }
func (*Media) Streams() []Stream                { return nil }
func (*Media) StreamCount() int                 { return 0 }
func (*Media) Duration() (time.Duration, error) { return 0, ErrNoVideo }
func (*Media) FormatName() string               { return "" }
func (*Media) FormatLongName() string           { return "" }
func (*Media) FormatMIMEType() string           { return "" }
func (*Media) ReadPacket() (*Packet, bool, error) {
	return nil, false, ErrNoVideo
}
