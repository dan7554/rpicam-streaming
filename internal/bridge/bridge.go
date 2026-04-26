package bridge

import (
	"fmt"
	"log"
	"sync"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/pion/rtp"
)

// Bridge is an RTSP switching proxy. It connects to multiple camera RTSP
// streams simultaneously and serves a single output stream. Switching cameras
// changes which source's packets are forwarded — zero-gap.
type Bridge struct {
	mu           sync.RWMutex
	addr         string
	rtspBase     string
	active       string
	server       *gortsplib.Server
	stream       *gortsplib.ServerStream
	clients      []*gortsplib.Client
	serverMedias []*description.Media
}

// New creates a bridge that listens on addr (e.g. ":8555") and reads cameras
// from rtspBase (e.g. "rtsp://localhost:8554").
func New(addr, rtspBase string) *Bridge {
	return &Bridge{
		addr:     addr,
		rtspBase: rtspBase,
	}
}

// Start connects to all cameras and starts the RTSP server.
func (b *Bridge) Start(cameras []string, active string) error {
	b.mu.Lock()
	b.active = active
	b.mu.Unlock()

	b.server = &gortsplib.Server{
		Handler:     b,
		RTSPAddress: b.addr,
	}
	if err := b.server.Start(); err != nil {
		return fmt.Errorf("bridge server: %w", err)
	}

	for i, cam := range cameras {
		if err := b.connectCamera(cam, i == 0); err != nil {
			b.Stop()
			return fmt.Errorf("connect %s: %w", cam, err)
		}
	}

	log.Printf("Bridge started on rtsp://localhost%s/stream (%d cameras, active: %s)",
		b.addr, len(cameras), active)
	return nil
}

func (b *Bridge) connectCamera(name string, first bool) error {
	rawURL := b.rtspBase + "/" + name
	u, err := base.ParseURL(rawURL)
	if err != nil {
		return err
	}

	c := &gortsplib.Client{
		Scheme: u.Scheme,
		Host:   u.Host,
	}
	if err := c.Start(); err != nil {
		return err
	}

	desc, _, err := c.Describe(u)
	if err != nil {
		c.Close()
		return err
	}

	if err := c.SetupAll(desc.BaseURL, desc.Medias); err != nil {
		c.Close()
		return err
	}

	if first {
		b.stream = &gortsplib.ServerStream{
			Server: b.server,
			Desc:   desc,
		}
		if err := b.stream.Initialize(); err != nil {
			c.Close()
			return err
		}
		b.serverMedias = desc.Medias
	}

	// Map client media pointers → server media pointers (by index).
	// All cameras must produce the same media layout.
	mediaMap := make(map[*description.Media]*description.Media, len(desc.Medias))
	for i, cm := range desc.Medias {
		if i < len(b.serverMedias) {
			mediaMap[cm] = b.serverMedias[i]
		}
	}

	camName := name
	c.OnPacketRTPAny(func(medi *description.Media, _ format.Format, pkt *rtp.Packet) {
		b.mu.RLock()
		isActive := b.active == camName
		b.mu.RUnlock()
		if !isActive {
			return
		}
		if sm, ok := mediaMap[medi]; ok {
			if err := b.stream.WritePacketRTP(sm, pkt); err != nil {
				log.Printf("bridge write error: %v", err)
			}
		}
	})

	if _, err := c.Play(nil); err != nil {
		c.Close()
		return err
	}

	b.clients = append(b.clients, c)
	return nil
}

// Switch changes the active camera atomically (zero-gap).
func (b *Bridge) Switch(camera string) {
	b.mu.Lock()
	b.active = camera
	b.mu.Unlock()
	log.Printf("Bridge switched to %s", camera)
}

// ProxyURL returns the RTSP URL of the bridge output.
func (b *Bridge) ProxyURL() string {
	return "rtsp://localhost" + b.addr + "/stream"
}

// Stop shuts down the bridge server and all camera connections.
func (b *Bridge) Stop() {
	for _, c := range b.clients {
		c.Close()
	}
	b.clients = nil
	if b.stream != nil {
		b.stream.Close()
		b.stream = nil
	}
	if b.server != nil {
		b.server.Close()
		b.server = nil
	}
	log.Printf("Bridge stopped")
}

// RTSP server handler implementations

func (b *Bridge) OnConnOpen(_ *gortsplib.ServerHandlerOnConnOpenCtx)     {}
func (b *Bridge) OnConnClose(_ *gortsplib.ServerHandlerOnConnCloseCtx)   {}
func (b *Bridge) OnSessionOpen(_ *gortsplib.ServerHandlerOnSessionOpenCtx)   {}
func (b *Bridge) OnSessionClose(_ *gortsplib.ServerHandlerOnSessionCloseCtx) {}

func (b *Bridge) OnDescribe(_ *gortsplib.ServerHandlerOnDescribeCtx) (*base.Response, *gortsplib.ServerStream, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.stream == nil {
		return &base.Response{StatusCode: base.StatusNotFound}, nil, nil
	}
	return &base.Response{StatusCode: base.StatusOK}, b.stream, nil
}

func (b *Bridge) OnSetup(_ *gortsplib.ServerHandlerOnSetupCtx) (*base.Response, *gortsplib.ServerStream, error) {
	b.mu.RLock()
	defer b.mu.RUnlock()
	if b.stream == nil {
		return &base.Response{StatusCode: base.StatusNotFound}, nil, nil
	}
	return &base.Response{StatusCode: base.StatusOK}, b.stream, nil
}

func (b *Bridge) OnPlay(_ *gortsplib.ServerHandlerOnPlayCtx) (*base.Response, error) {
	return &base.Response{StatusCode: base.StatusOK}, nil
}
