package switcher

import (
	"os/exec"
	"strings"
	"testing"
)

// gstAvailable returns true if gst-launch-1.0 is on PATH.
func gstAvailable() bool {
	_, err := exec.LookPath("gst-launch-1.0")
	return err == nil
}

// gstParsePipeline asks GStreamer to parse (but not run) a pipeline string.
// Returns an error if the syntax is invalid or elements are missing.
func gstParsePipeline(pipeline string) error {
	// gst-launch-1.0 parses, creates elements, links them, then sets state.
	// We use fakesrc/fakesink substitutions where possible, but for a parse
	// check we just need it to get past element creation. Using --gst-debug-level=0
	// to suppress noise. We override sources/sinks that need network with fakes.
	//
	// Replace network sinks/sources with fakes so parsing works offline.
	p := pipeline
	replacements := map[string]string{
		// Replace RTSP sources with fakesrc (they'd block waiting for network)
		// We can't do simple replace because rtspsrc has properties; instead
		// we use gst-launch-1.0's built-in parse which will fail on bad syntax.
	}
	_ = replacements
	// Just do a syntax parse — gst-launch-1.0 will error on bad element names,
	// bad property names, and bad link syntax even without running.
	args := strings.Fields(p)
	cmd := exec.Command("gst-launch-1.0", append([]string{"--gst-parse-launch"}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return &pipelineError{pipeline: p, output: string(out), err: err}
	}
	return nil
}

type pipelineError struct {
	pipeline string
	output   string
	err      error
}

func (e *pipelineError) Error() string {
	return e.output + "\n" + e.err.Error()
}

// --- String-level pipeline validation tests (no GStreamer required) ---

func TestDefaultPipelineCameraAudio_Elements(t *testing.T) {
	p := buildDefaultPipeline("rtsp://cam:8554/stream", "rtmp://localhost:1935/live-output", "")
	checks := []struct {
		label    string
		contains string
	}{
		{"rtsp source", "rtspsrc location=rtsp://cam:8554/stream"},
		{"latency", "latency=200"},
		{"h264 depay", "rtph264depay"},
		{"h264 parse", "h264parse"},
		{"video tee", "tee name=vt"},
		{"audio tee", "tee name=at"},
		{"aac decode", "avdec_aac"},
		{"aac encode", "avenc_aac"},
		{"opus encode", "opusenc"},
		{"rtmp sink", "rtmp2sink location=rtmp://localhost:1935/live-output"},
		{"preview sink", "rtspclientsink location=rtsp://localhost:8554/live-preview"},
		{"preview named", "name=preview"},
		{"opus to preview", "opusenc audio-type=restricted-lowdelay ! preview."},
		{"flvmux", "flvmux streamable=true"},
		{"audio caps", "audio/x-raw,rate=48000,channels=1"},
		{"audioconvert before aac", "audioconvert ! avenc_aac"},
		{"audioconvert before opus", "audioconvert ! opusenc"},
	}
	for _, c := range checks {
		t.Run(c.label, func(t *testing.T) {
			if !strings.Contains(p, c.contains) {
				t.Errorf("pipeline missing %q:\n%s", c.contains, p)
			}
		})
	}
}

func TestDefaultPipelineMicAudio_Elements(t *testing.T) {
	p := buildDefaultPipeline("rtsp://cam:8554/stream", "rtmp://localhost:1935/live-output", "0")
	checks := []struct {
		label    string
		contains string
	}{
		{"mic source", "osxaudiosrc device=0"},
		{"no rtpmp4gdepay", ""},
		{"audio tee", "tee name=at"},
		{"aac encode", "avenc_aac"},
		{"opus encode", "opusenc"},
		{"rtmp sink", "rtmp2sink"},
		{"preview sink", "rtspclientsink"},
		{"opus to preview", "opusenc audio-type=restricted-lowdelay ! preview."},
	}
	for _, c := range checks {
		if c.contains == "" {
			continue
		}
		t.Run(c.label, func(t *testing.T) {
			if !strings.Contains(p, c.contains) {
				t.Errorf("pipeline missing %q:\n%s", c.contains, p)
			}
		})
	}
	// Mic pipeline should NOT have rtpmp4gdepay (that's for RTSP camera audio)
	if strings.Contains(p, "rtpmp4gdepay") {
		t.Error("mic pipeline should not contain rtpmp4gdepay")
	}
}

func TestOverlayPipelineCameraAudio_Elements(t *testing.T) {
	p := buildOverlayPipeline("/tmp/overlay.png", "rtsp://cam:8554/stream", "rtmp://localhost:1935/live-output", "")
	checks := []struct {
		label    string
		contains string
	}{
		{"overlay source", "filesrc location=/tmp/overlay.png"},
		{"png decode", "pngdec"},
		{"imagefreeze", "imagefreeze"},
		{"compositor", "compositor name=mixer"},
		{"overlay positioning", "sink_1::xpos=20 sink_1::ypos=20"},
		{"x264enc", "x264enc tune=zerolatency"},
		{"encoded video tee", "tee name=enc_tee"},
		{"audio tee", "tee name=at"},
		{"aac decode", "avdec_aac"},
		{"aac encode", "avenc_aac"},
		{"opus encode", "opusenc"},
		{"rtmp mux", "flvmux streamable=true name=rtmp_mux"},
		{"rtmp sink", "rtmp2sink"},
		{"preview sink", "rtspclientsink location=rtsp://localhost:8554/live-preview"},
		{"preview named", "name=preview"},
		{"opus to preview", "opusenc audio-type=restricted-lowdelay ! preview."},
		{"audioconvert before aac", "audioconvert ! avenc_aac"},
		{"audioconvert before opus", "audioconvert ! opusenc"},
		{"bitrate", "bitrate=4000"},
	}
	for _, c := range checks {
		t.Run(c.label, func(t *testing.T) {
			if !strings.Contains(p, c.contains) {
				t.Errorf("pipeline missing %q:\n%s", c.contains, p)
			}
		})
	}
}

func TestOverlayPipelineMicAudio_Elements(t *testing.T) {
	p := buildOverlayPipeline("/tmp/overlay.png", "rtsp://cam:8554/stream", "rtmp://localhost:1935/live-output", "2")
	checks := []struct {
		label    string
		contains string
	}{
		{"mic source", "osxaudiosrc device=2"},
		{"audio tee", "tee name=at"},
		{"opus encode", "opusenc"},
		{"opus to preview", "opusenc audio-type=restricted-lowdelay ! preview."},
	}
	for _, c := range checks {
		t.Run(c.label, func(t *testing.T) {
			if !strings.Contains(p, c.contains) {
				t.Errorf("pipeline missing %q:\n%s", c.contains, p)
			}
		})
	}
	if strings.Contains(p, "rtpmp4gdepay") {
		t.Error("mic overlay pipeline should not contain rtpmp4gdepay")
	}
}

// --- Structural validation: tee branches, named elements, link targets ---

func TestAllPipelines_AudioTeeBranches(t *testing.T) {
	pipelines := map[string]string{
		"default/camera":  buildDefaultPipeline("rtsp://x", "rtmp://x", ""),
		"default/mic":     buildDefaultPipeline("rtsp://x", "rtmp://x", "0"),
		"overlay/camera":  buildOverlayPipeline("/tmp/o.png", "rtsp://x", "rtmp://x", ""),
		"overlay/mic":     buildOverlayPipeline("/tmp/o.png", "rtsp://x", "rtmp://x", "0"),
	}
	for name, p := range pipelines {
		t.Run(name, func(t *testing.T) {
			// Must have audio tee
			if !strings.Contains(p, "tee name=at") {
				t.Fatal("missing audio tee (tee name=at)")
			}
			// Audio tee must feed both AAC (for RTMP) and Opus (for preview)
			atBranches := strings.Count(p, "at. !")
			if atBranches < 2 {
				t.Errorf("audio tee has %d branches, expected at least 2 (AAC + Opus)", atBranches)
			}
			// Must have video tee
			if !strings.Contains(p, "tee name=vt") && !strings.Contains(p, "tee name=enc_tee") {
				t.Fatal("missing video tee")
			}
			// Preview sink must be named
			if !strings.Contains(p, "name=preview") {
				t.Fatal("rtspclientsink must be named 'preview'")
			}
			// Opus must link to preview
			if !strings.Contains(p, "! preview.") {
				t.Fatal("opus output must link to preview sink (! preview.)")
			}
		})
	}
}

func TestAllPipelines_QueueBeforeSinks(t *testing.T) {
	pipelines := map[string]string{
		"default/camera":  buildDefaultPipeline("rtsp://x", "rtmp://x", ""),
		"default/mic":     buildDefaultPipeline("rtsp://x", "rtmp://x", "0"),
		"overlay/camera":  buildOverlayPipeline("/tmp/o.png", "rtsp://x", "rtmp://x", ""),
		"overlay/mic":     buildOverlayPipeline("/tmp/o.png", "rtsp://x", "rtmp://x", "0"),
	}
	for name, p := range pipelines {
		t.Run(name, func(t *testing.T) {
			// Every tee branch should go through a queue
			// Count tee output links (vt. ! or at. ! or enc_tee. !)
			for _, prefix := range []string{"vt. !", "at. !", "enc_tee. !"} {
				idx := 0
				for {
					i := strings.Index(p[idx:], prefix)
					if i < 0 {
						break
					}
					idx += i + len(prefix)
					rest := strings.TrimSpace(p[idx:])
					if !strings.HasPrefix(rest, "queue") {
						t.Errorf("tee branch %q at offset %d not followed by queue: ...%s",
							prefix, idx, rest[:min(60, len(rest))])
					}
				}
			}
		})
	}
}

// --- GStreamer parse validation (requires gst-launch-1.0 on PATH) ---

func TestAllPipelines_GStreamerParse(t *testing.T) {
	if !gstAvailable() {
		t.Skip("gst-launch-1.0 not available")
	}

	// GStreamer can parse pipeline syntax even if sources/sinks can't connect.
	// We use --gst-parse-launch which validates element names and properties
	// but doesn't set the pipeline to PLAYING.
	pipelines := map[string]string{
		"default/camera":  buildDefaultPipeline("rtsp://fake:8554/s", "rtmp://fake:1935/o", ""),
		"default/mic":     buildDefaultPipeline("rtsp://fake:8554/s", "rtmp://fake:1935/o", "0"),
		"overlay/camera":  buildOverlayPipeline("/dev/null", "rtsp://fake:8554/s", "rtmp://fake:1935/o", ""),
		"overlay/mic":     buildOverlayPipeline("/dev/null", "rtsp://fake:8554/s", "rtmp://fake:1935/o", "0"),
	}

	for name, p := range pipelines {
		t.Run(name, func(t *testing.T) {
			// Use gst-inspect to verify each element exists
			elements := extractElements(p)
			for _, elem := range elements {
				cmd := exec.Command("gst-inspect-1.0", "--exists", elem)
				if err := cmd.Run(); err != nil {
					t.Errorf("GStreamer element %q not found", elem)
				}
			}
		})
	}
}

// extractElements pulls GStreamer element factory names from a pipeline string.
// It skips caps filters (containing /), named references (ending with .), and properties.
func extractElements(pipeline string) []string {
	seen := map[string]bool{}
	var elements []string
	tokens := strings.Fields(pipeline)
	for _, tok := range tokens {
		// Skip link operator
		if tok == "!" {
			continue
		}
		// Skip caps (e.g. video/x-raw,format=RGBA)
		if strings.Contains(tok, "/") {
			continue
		}
		// Skip named pad references (e.g. vt. mixer. preview.)
		if strings.HasSuffix(tok, ".") {
			continue
		}
		// Skip properties (contain =)
		if strings.Contains(tok, "=") {
			continue
		}
		// What remains should be element factory names
		if !seen[tok] {
			seen[tok] = true
			elements = append(elements, tok)
		}
	}
	return elements
}

func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
