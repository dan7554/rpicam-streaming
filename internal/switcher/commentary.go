package switcher

// Commentary audio mixing is built into the always-on pipeline in switcher.go.
// The pipeline always includes an audiomixer with 2 commentary RTSP sources.
// Silence publishers maintain the streams when no commentator is connected,
// and MediaMTX overridePublisher allows WHIP to seamlessly replace silence
// with real audio. No separate pipeline builder is needed.
