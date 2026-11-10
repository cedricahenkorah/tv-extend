// sendfile streams a recorded .h264 file (from the Mac app's Phase 1 recorder) to the
// TV app, using the wire protocol in protocol.md. It's a test tool for the TV side.
//
//	go run ./sendfile -tv 192.168.1.42              # newest recording in ~/Movies/TV Extend
//	go run ./sendfile -tv 192.168.1.42 -loop -file capture.h264
package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"sort"
	"time"
)

// Protocol constants (see protocol.md).
const (
	port         = 48100
	magic        = 0x5458
	headerSize   = 16
	flagKeyframe = 0x01

	msgHello           = 0x01
	msgHelloAck        = 0x02
	msgCodecConfig     = 0x10
	msgFrame           = 0x11
	msgRequestKeyframe = 0x20
	msgPing            = 0x30
	msgPong            = 0x31
	msgBye             = 0x7F
)

var startCode = []byte{0, 0, 0, 1}

// frame is one access unit ready to send.
type frame struct {
	config   []byte // SPS+PPS in Annex B, set when the file has them before this frame
	data     []byte // the frame's NAL units in Annex B
	keyframe bool
}

func main() {
	tv := flag.String("tv", "", "TV IP address (shown on the TV app's screen)")
	file := flag.String("file", "", "path to a .h264 recording (default: newest in ~/Movies/TV Extend)")
	fps := flag.Int("fps", 60, "playback rate in frames per second")
	loop := flag.Bool("loop", false, "repeat the file until interrupted")
	flag.Parse()

	if *tv == "" {
		flag.Usage()
		os.Exit(2)
	}
	if *file == "" {
		f, err := newestRecording()
		if err != nil {
			log.Fatal(err)
		}
		*file = f
	}

	raw, err := os.ReadFile(*file)
	if err != nil {
		log.Fatal(err)
	}
	frames := splitFrames(raw)
	if len(frames) == 0 || !frames[0].keyframe {
		log.Fatalf("%s: no frames found, or it doesn't start with a keyframe", *file)
	}
	log.Printf("loaded %s: %d frames (%.1f MB)", filepath.Base(*file), len(frames), float64(len(raw))/1e6)

	if err := stream(*tv, frames, *fps, *loop); err != nil {
		log.Fatal(err)
	}
}

func stream(tv string, frames []frame, fps int, loop bool) error {
	addr := net.JoinHostPort(tv, fmt.Sprint(port))
	conn, err := net.DialTimeout("tcp", addr, 5*time.Second)
	if err != nil {
		return fmt.Errorf("connecting to %s: %w (is the TV app open?)", addr, err)
	}
	defer conn.Close()
	log.Printf("connected to %s", addr)

	w := bufio.NewWriterSize(conn, 256*1024)
	start := time.Now()
	now := func() uint64 { return uint64(time.Since(start).Microseconds()) }

	hello, _ := json.Marshal(map[string]any{"version": 1, "codec": "avc", "width": 1920, "height": 1080, "fps": fps})
	if err := send(w, msgHello, 0, now(), hello); err != nil {
		return err
	}

	// Wait for the TV to accept before streaming.
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	r := bufio.NewReader(conn)
	typ, _, _, payload, err := receive(r)
	if err != nil {
		return fmt.Errorf("waiting for HELLO_ACK: %w", err)
	}
	if typ != msgHelloAck {
		return fmt.Errorf("TV rejected the connection (message type 0x%02x)", typ)
	}
	conn.SetReadDeadline(time.Time{})
	log.Printf("TV accepted: %s", payload)

	// Messages from the TV arrive in the background: PONGs and keyframe requests.
	go func() {
		for {
			typ, _, ts, _, err := receive(r)
			if err != nil {
				return
			}
			switch typ {
			case msgPong:
				log.Printf("round trip: %.1f ms", float64(now()-ts)/1000)
			case msgRequestKeyframe:
				log.Printf("TV asked for a keyframe (the file will send one at its next keyframe)")
			case msgBye:
				log.Printf("TV closed the connection")
				conn.Close()
				return
			}
		}
	}()

	interval := time.Second / time.Duration(fps)
	next := time.Now()
	lastPing := time.Now()
	sent := 0

	for {
		for _, f := range frames {
			if f.config != nil {
				if err := send(w, msgCodecConfig, 0, now(), f.config); err != nil {
					return err
				}
			}
			var flags byte
			if f.keyframe {
				flags = flagKeyframe
			}
			if err := send(w, msgFrame, flags, now(), f.data); err != nil {
				return err
			}
			sent++

			if time.Since(lastPing) > time.Second {
				lastPing = time.Now()
				if err := send(w, msgPing, 0, now(), nil); err != nil {
					return err
				}
				log.Printf("sent %d frames", sent)
			}

			next = next.Add(interval)
			time.Sleep(time.Until(next))
		}
		if !loop {
			break
		}
	}

	log.Printf("done: sent %d frames", sent)
	return send(w, msgBye, 0, now(), nil)
}

// send writes one message and flushes it right away (low latency over throughput).
func send(w *bufio.Writer, typ, flags byte, ts uint64, payload []byte) error {
	var h [headerSize]byte
	binary.BigEndian.PutUint16(h[0:], magic)
	h[2] = typ
	h[3] = flags
	binary.BigEndian.PutUint32(h[4:], uint32(len(payload)))
	binary.BigEndian.PutUint64(h[8:], ts)
	if _, err := w.Write(h[:]); err != nil {
		return err
	}
	if _, err := w.Write(payload); err != nil {
		return err
	}
	return w.Flush()
}

func receive(r io.Reader) (typ, flags byte, ts uint64, payload []byte, err error) {
	var h [headerSize]byte
	if _, err = io.ReadFull(r, h[:]); err != nil {
		return
	}
	if binary.BigEndian.Uint16(h[0:]) != magic {
		err = errors.New("bad magic from TV")
		return
	}
	typ, flags = h[2], h[3]
	ts = binary.BigEndian.Uint64(h[8:])
	payload = make([]byte, binary.BigEndian.Uint32(h[4:]))
	_, err = io.ReadFull(r, payload)
	return
}

// splitFrames groups an Annex B stream into frames. SPS/PPS (NAL types 7/8) become the
// next frame's config; each slice (types 1/5) ends a frame. The Mac encoder emits one
// slice per frame, so this is enough for our own recordings.
func splitFrames(stream []byte) []frame {
	var frames []frame
	var config, pending []byte
	for _, nal := range splitNALs(stream) {
		if len(nal) == 0 {
			continue
		}
		switch nal[0] & 0x1F {
		case 7, 8: // SPS, PPS
			config = append(append(config, startCode...), nal...)
		case 1, 5: // non-IDR slice, IDR slice
			pending = append(append(pending, startCode...), nal...)
			frames = append(frames, frame{config: config, data: pending, keyframe: nal[0]&0x1F == 5})
			config, pending = nil, nil
		default: // SEI, AUD, ... ride along with the next slice
			pending = append(append(pending, startCode...), nal...)
		}
	}
	return frames
}

// splitNALs returns the NAL units between 3- or 4-byte start codes.
func splitNALs(b []byte) [][]byte {
	var nals [][]byte
	sep := []byte{0, 0, 1}
	i := bytes.Index(b, sep)
	for i >= 0 {
		begin := i + len(sep)
		next := bytes.Index(b[begin:], sep)
		if next < 0 {
			nals = append(nals, b[begin:])
			break
		}
		end := begin + next
		// A 4-byte start code leaves a trailing zero on the previous NAL.
		nalEnd := end
		if nalEnd > begin && b[nalEnd-1] == 0 {
			nalEnd--
		}
		nals = append(nals, b[begin:nalEnd])
		i = end
	}
	return nals
}

func newestRecording() (string, error) {
	home, _ := os.UserHomeDir()
	matches, _ := filepath.Glob(filepath.Join(home, "Movies", "TV Extend", "*.h264"))
	type entry struct {
		path string
		mod  time.Time
	}
	var files []entry
	for _, m := range matches {
		if info, err := os.Stat(m); err == nil && info.Size() > 0 {
			files = append(files, entry{m, info.ModTime()})
		}
	}
	if len(files) == 0 {
		return "", errors.New("no recordings in ~/Movies/TV Extend; record one with the Mac app first, or pass -file")
	}
	sort.Slice(files, func(a, b int) bool { return files[a].mod.After(files[b].mod) })
	return files[0].path, nil
}
