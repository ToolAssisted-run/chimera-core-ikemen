//go:build chimera

// The media check, built only into the test build tests/media/run-media.sh
// makes (CHIMERA_VARIANT=media), never into the core: once the game's
// settings are read, the core pulls every music file and every sound of the
// game's folder through the engine's own playback - the decoder Bgm.Open
// picks by the file's name (bgmDecode, patch 0008), the SND reader, the
// looper and the resampler to
// the core's 44100 Hz - as fast as it can instead of a frame at a time, and
// prints what came out:
//
//	music <path> <status> rate=<source rate> frames=<frames out> sha1=<of the 16-bit sound>
//	snd <snd path> sounds=<how many>
//	sound <snd path> <group>,<number> <status> rate=... frames=... sha1=...
//	env <loudness of every 735 frames out (a frame's worth), 16-bit RMS>
//
// with a tab between fields (names have spaces).
//
// tests/media/check-media.py compares that with ffmpeg's decoding.
package main

import (
	"crypto/sha1"
	"encoding/hex"
	"fmt"
	"math"
	"path"
	"runtime"
	"sort"
	"strings"

	"github.com/gopxl/beep/v2"
)

func init() {
	chimeraMediaCheck = mediaCheck
}

// what counts as music: the names Ikemen GO's decoders read, and other sound
// formats, which go to the core's FFmpeg
var mediaMusicNames = map[string]bool{".ogg": true, ".mp3": true, ".wav": true, ".flac": true, ".xm": true,
	".mod": true, ".it": true, ".s3m": true, ".mpc": true, ".wma": true, ".aac": true, ".m4a": true,
	".opus": true, ".ape": true, ".mp2": true, ".aif": true, ".aiff": true, ".umx": true}

func mediaFiles() []string {
	var out []string
	var visit func(n *fsNode, p string)
	visit = func(n *fsNode, p string) {
		for _, k := range n.kids {
			kp := path.Join(p, k.name)
			if k.dir {
				visit(k, kp)
			} else {
				out = append(out, kp)
			}
		}
	}
	fsys.Lock()
	visit(fsys.root, "")
	fsys.Unlock()
	sort.Strings(out)
	return out
}

// mediaPull streams s to its end and prints the result and its loudness.
func mediaPull(head string, s beep.Streamer, rate beep.SampleRate, quality int) {
	r := beep.Resample(quality, rate, beep.SampleRate(44100), s)
	h := sha1.New()
	var env []string
	var buf [512][2]float64
	var sum float64
	var inFrame, frames int
	var pcm [4]byte
	for {
		n, ok := r.Stream(buf[:])
		for _, smp := range buf[:n] {
			for c := 0; c < 2; c++ {
				v := math.Max(-1, math.Min(1, smp[c]))
				i := int16(math.Round(v * 32767))
				pcm[2*c], pcm[2*c+1] = byte(i), byte(uint16(i)>>8)
				sum += float64(i) * float64(i)
			}
			h.Write(pcm[:])
			inFrame++
			if inFrame == 735 {
				env = append(env, fmt.Sprint(int(math.Sqrt(sum/1470))))
				sum, inFrame = 0, 0
			}
		}
		frames += n
		if n == 0 || !ok {
			break
		}
	}
	if inFrame > 0 {
		env = append(env, fmt.Sprint(int(math.Sqrt(sum/float64(2*inFrame)))))
	}
	status := "ok"
	if err := r.Err(); err != nil {
		status = "error: " + err.Error()
	}
	fmt.Printf("%s\t%s\trate=%d\tframes=%d\tsha1=%s\n", head, status, rate, frames, hex.EncodeToString(h.Sum(nil)))
	fmt.Printf("env\t%s\n", strings.Join(env, ","))
}

func mediaMusic(p string, quality int) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Printf("music\t%s\tpanic: %v\n", p, r)
		}
	}()
	f, err := OpenFile(p)
	if err != nil {
		fmt.Printf("music\t%s\topen: %v\n", p, err)
		return
	}
	defer f.Close()
	// the decoder Bgm.Open picks
	st, format, _, err := bgmDecode(f, p)
	if err != nil {
		fmt.Printf("music\t%s\tdecode: %v\n", p, err)
		return
	}
	// once through, as the music player's looper and seeker hold it
	sw := newSwapSeeker(st)
	mediaPull("music\t"+p, newStreamLooper(sw, 0, 0, st.Len()), format.SampleRate, quality)
}

func mediaSnd(p string, quality int) {
	defer func() {
		if r := recover(); r != nil {
			fmt.Printf("sound\t%s\t-\tpanic: %v\n", p, r)
		}
	}()
	// as LoadSnd reads it (it switches off a sound it cannot play to the end)
	snd, err := LoadSndFiltered(p, func(gn [2]int32) bool { return gn[0] >= 0 && gn[1] >= 0 }, 0)
	if err != nil {
		fmt.Printf("sound\t%s\t-\tload: %v\n", p, strings.ReplaceAll(err.Error(), "\n", " "))
		return
	}
	var keys [][2]int32
	for k := range snd.table {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		return keys[i][0] < keys[j][0] || keys[i][0] == keys[j][0] && keys[i][1] < keys[j][1]
	})
	fmt.Printf("snd\t%s\tsounds=%d\n", p, len(keys))
	for _, k := range keys {
		s := snd.table[k]
		head := fmt.Sprintf("sound\t%s\t%d,%d", p, k[0], k[1])
		if s == nil {
			fmt.Printf("%s\tdisabled\n", head)
			continue
		}
		// as a sound channel plays it, at full volume, in the middle
		fx := &SoundEffect{streamer: newStreamLooper(s.GetStreamer(), 0, 0, 0), volume: 256, freqmul: 1}
		mediaPull(head, fx, s.format.SampleRate, quality)
	}
}

func mediaCheck(cfg *Config) {
	quality := int(cfg.Sound.AudioResampleQuality)
	if quality < 1 {
		quality = 1
	} else if quality > 16 {
		quality = 16
	}
	fmt.Printf("media check: resampling quality %d\n", quality)
	for _, p := range mediaFiles() {
		ext := strings.ToLower(path.Ext(p))
		switch {
		case ext == ".snd":
			mediaSnd(p, quality)
		case mediaMusicNames[ext]:
			mediaMusic(p, quality)
		}
		// the check runs in one go, within the start, and the sandbox's one
		// thread never gives the collector's workers a turn: a collection
		// after each file, or the memory of every file stays taken
		runtime.GC()
	}
	chimeraFail("media check finished")
}
