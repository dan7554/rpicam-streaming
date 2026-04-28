package switcher

import (
	"fmt"
	"log"
	"os/exec"
	"strings"
)

// commentaryAudioSrc builds the audio source segment for commentary mixing.
// It creates an audiomixer that blends camera audio with active commentary slots.
// Returns the pipeline segment that produces a raw audio tee named "at".
func commentaryAudioSrc(camAudioPad, rtspBase string, cc CommentaryConfig) string {
	// Camera audio → volume → audiomixer
	parts := []string{
		fmt.Sprintf("%s ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! volume name=camvol volume=%.2f ! audiomixer name=amix latency=200000000",
			camAudioPad, cc.CameraVolume),
	}

	// Each active commentary slot: pull from RTSP, decode opus, volume → amix
	for i, slot := range cc.Slots {
		if !slot.Active {
			continue
		}
		name := fmt.Sprintf("commentary-%d", i+1)
		parts = append(parts, fmt.Sprintf(
			"rtspsrc location=%s/%s protocols=tcp latency=200 name=comm%d "+
				"comm%d. ! rtpopusdepay ! opusdec ! audioconvert ! audioresample ! audio/x-raw,rate=48000,channels=1 ! "+
				"volume name=comm%dvol volume=%.2f ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! amix.",
			rtspBase, name, i+1, i+1, i+1, slot.Volume))
	}

	// audiomixer output → audiorate → tee
	parts = append(parts, "amix. ! audiorate ! tee name=at")

	return strings.Join(parts, " ")
}

// buildDefaultCommentaryPipeline builds the default pipeline with commentary audio mixing.
func buildDefaultCommentaryPipeline(rtspURL, rtmpURL, rtspBase string, cc CommentaryConfig) string {
	audioSrc := commentaryAudioSrc(
		"src. ! rtpmp4gdepay ! aacparse ! avdec_aac",
		rtspBase, cc)

	return fmt.Sprintf(
		"rtspsrc location=%s protocols=tcp latency=200 name=src "+
			"src. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! tee name=vt "+
			"%s "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! flvmux streamable=true name=flvm "+
			"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! flvm. "+
			"flvm. ! rtmpsink location=%s "+
			"vt. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
		rtspURL, audioSrc, rtmpURL)
}

// buildOverlayCommentaryPipeline builds the overlay pipeline with commentary audio mixing.
func buildOverlayCommentaryPipeline(overlayPath, rtspURL, rtmpURL, rtspBase string, cc CommentaryConfig) string {
	audioSrc := commentaryAudioSrc(
		"cam. ! rtpmp4gdepay ! aacparse ! avdec_aac",
		rtspBase, cc)

	return fmt.Sprintf(
		"filesrc location=%s ! pngdec ! imagefreeze ! video/x-raw,framerate=30/1 ! queue name=overlay_img "+
			"rtspsrc location=%s protocols=tcp latency=200 name=cam "+
			"cam. ! rtph264depay ! h264parse ! video/x-h264,stream-format=avc,alignment=au ! avdec_h264 ! videoconvert ! video/x-raw,format=RGBA ! queue ! compositor name=mixer sink_1::xpos=20 sink_1::ypos=20 ! videoconvert ! x264enc tune=zerolatency speed-preset=ultrafast key-int-max=30 bframes=0 bitrate=4000 ! h264parse ! tee name=enc_tee "+
			"overlay_img. ! mixer. "+
			"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! flvmux streamable=true name=rtmp_mux "+
			"rtmp_mux. ! rtmpsink location=%s "+
			"%s "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! avenc_aac ! aacparse ! rtmp_mux. "+
			"enc_tee. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! rtspclientsink location=rtsp://localhost:8554/live-preview protocols=tcp name=preview "+
			"at. ! queue max-size-buffers=0 max-size-time=3000000000 max-size-bytes=0 leaky=downstream ! audioconvert ! opusenc audio-type=restricted-lowdelay ! preview.",
		overlayPath, rtspURL, rtmpURL, audioSrc)
}

// commentaryCmdFactory creates a CmdFactory that builds a commentary-mixing pipeline.
func commentaryCmdFactory(rtspBase string, cc CommentaryConfig, overlayPath string) CmdFactory {
	return func(rtspURL, rtmpURL, audioDevice string) *exec.Cmd {
		var pipeline string
		if overlayPath != "" {
			log.Printf("[switcher] building OVERLAY+COMMENTARY pipeline: %s → %s (overlay=%s, %d slots)", rtspURL, rtmpURL, overlayPath, len(cc.Slots))
			pipeline = buildOverlayCommentaryPipeline(overlayPath, rtspURL, rtmpURL, rtspBase, cc)
		} else {
			log.Printf("[switcher] building COMMENTARY pipeline: %s → %s (%d slots)", rtspURL, rtmpURL, len(cc.Slots))
			pipeline = buildDefaultCommentaryPipeline(rtspURL, rtmpURL, rtspBase, cc)
		}
		log.Printf("[switcher] GStreamer commentary pipeline: %s", pipeline)
		args := append([]string{"-e"}, strings.Fields(pipeline)...)
		return exec.Command("gst-launch-1.0", args...)
	}
}
