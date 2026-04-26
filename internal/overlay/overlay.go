package overlay

import (
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"time"

	"golang.org/x/image/font"
	"golang.org/x/image/font/inconsolata"
	"golang.org/x/image/math/fixed"
)

// Competitor represents a single entry in the timing tower.
type Competitor struct {
	Pos     string `json:"pos"`
	Number  string `json:"dNo"`
	Name    string `json:"nam"`
	LastLap string `json:"lsTm"`
	BestLap string `json:"btTm"`
	Gap     string `json:"gp"`
	Diff    string `json:"df"`
	Laps    int    `json:"ls"`
	Class   string `json:"cln"`
}

// sessionResp is the raw MYLAPS API response.
type sessionResp struct {
	Competitors []Competitor `json:"l"`
}

// Overlay polls a MYLAPS live timing session and renders a PNG timing tower.
type Overlay struct {
	mu          sync.RWMutex
	eventID     string
	sessionID   string
	apiBase     string
	pngPath     string
	competitors []Competitor
	sessionName string
	maxRows     int
	interval    time.Duration
	stopCh      chan struct{}
	wg          sync.WaitGroup
}

// Config for creating an overlay.
type Config struct {
	EventID   string
	SessionID string // if empty, uses /active endpoint
	PNGPath   string // where to write the overlay PNG
	MaxRows   int    // max competitors to show (default 10)
	Interval  time.Duration
}

func New(cfg Config) *Overlay {
	if cfg.MaxRows == 0 {
		cfg.MaxRows = 10
	}
	if cfg.Interval == 0 {
		cfg.Interval = 4 * time.Second
	}
	return &Overlay{
		eventID:   cfg.EventID,
		sessionID: cfg.SessionID,
		apiBase:   "https://lt-api.speedhive.com/api",
		pngPath:   cfg.PNGPath,
		maxRows:   cfg.MaxRows,
		interval:  cfg.Interval,
		stopCh:    make(chan struct{}),
	}
}

// Start begins polling and rendering.
func (o *Overlay) Start() {
	o.wg.Add(1)
	go func() {
		defer o.wg.Done()
		o.poll() // immediate first poll
		ticker := time.NewTicker(o.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				o.poll()
			case <-o.stopCh:
				return
			}
		}
	}()
	log.Printf("Overlay started: event=%s session=%s interval=%s", o.eventID, o.sessionID, o.interval)
}

// Stop halts polling.
func (o *Overlay) Stop() {
	close(o.stopCh)
	o.wg.Wait()
	log.Printf("Overlay stopped")
}

func (o *Overlay) poll() {
	var url string
	if o.sessionID != "" {
		url = fmt.Sprintf("%s/events/%s/sessions/%s/data", o.apiBase, o.eventID, o.sessionID)
	} else {
		url = fmt.Sprintf("%s/events/%s/active", o.apiBase, o.eventID)
	}

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		log.Printf("overlay request error: %v", err)
		return
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Origin", "https://speedhive.mylaps.com")
	req.Header.Set("Referer", "https://speedhive.mylaps.com/")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("overlay poll error: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		log.Printf("overlay poll: HTTP %d", resp.StatusCode)
		return
	}

	var data sessionResp
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		log.Printf("overlay decode error: %v", err)
		return
	}

	o.mu.Lock()
	o.competitors = data.Competitors
	if len(o.competitors) > 0 {
		o.sessionName = o.competitors[0].Class
	}
	o.mu.Unlock()

	if err := o.render(); err != nil {
		log.Printf("overlay render error: %v", err)
	}
}

// Competitors returns the current timing data.
func (o *Overlay) Competitors() []Competitor {
	o.mu.RLock()
	defer o.mu.RUnlock()
	result := make([]Competitor, len(o.competitors))
	copy(result, o.competitors)
	return result
}

// render draws the timing tower to a PNG file.
func (o *Overlay) render() error {
	o.mu.RLock()
	comps := o.competitors
	sessionName := o.sessionName
	o.mu.RUnlock()

	n := len(comps)
	if n > o.maxRows {
		n = o.maxRows
	}
	if n == 0 {
		return nil
	}

	face := inconsolata.Bold8x16

	const (
		rowH      = 22
		headerH   = 28
		padX      = 8
		charW     = 8 // inconsolata monospace char width
		colPos    = 30
		colNum    = 60
		colName   = 170
		colGap    = 90
		totalW    = colPos + colNum + colName + colGap + padX*2
	)
	totalH := headerH + rowH*n + 4

	img := image.NewRGBA(image.Rect(0, 0, totalW, totalH))

	// Semi-transparent dark background
	bgColor := color.RGBA{0, 0, 0, 200}
	for y := 0; y < totalH; y++ {
		for x := 0; x < totalW; x++ {
			img.SetRGBA(x, y, bgColor)
		}
	}

	// Header bar
	headerColor := color.RGBA{20, 20, 80, 230}
	for y := 0; y < headerH; y++ {
		for x := 0; x < totalW; x++ {
			img.SetRGBA(x, y, headerColor)
		}
	}

	white := color.RGBA{255, 255, 255, 255}
	yellow := color.RGBA{255, 255, 0, 255}
	gray := color.RGBA{180, 180, 180, 255}
	green := color.RGBA{0, 220, 100, 255}

	// Header text
	title := sessionName
	if len(title) > 40 {
		title = title[:40]
	}
	drawString(img, face, padX, headerH-8, title, white)

	// Column headers
	y0 := headerH
	drawString(img, face, padX, y0+rowH-6, "P", gray)
	drawString(img, face, padX+colPos, y0+rowH-6, "#", gray)
	drawString(img, face, padX+colPos+colNum, y0+rowH-6, "Name", gray)
	drawString(img, face, padX+colPos+colNum+colName, y0+rowH-6, "Gap", gray)

	// Stripe row header
	headerRowColor := color.RGBA{40, 40, 40, 200}
	for x := 0; x < totalW; x++ {
		for dy := 0; dy < rowH; dy++ {
			img.SetRGBA(x, y0+dy, headerRowColor)
		}
	}
	drawString(img, face, padX, y0+rowH-6, "P", gray)
	drawString(img, face, padX+colPos, y0+rowH-6, "#", gray)
	drawString(img, face, padX+colPos+colNum, y0+rowH-6, "Name", gray)
	drawString(img, face, padX+colPos+colNum+colName, y0+rowH-6, "Gap", gray)

	// Data rows
	for i := 0; i < n; i++ {
		c := comps[i]
		ry := y0 + rowH*(i+1)

		// Alternating row backgrounds
		if i%2 == 1 {
			rowBg := color.RGBA{30, 30, 30, 200}
			for x := 0; x < totalW; x++ {
				for dy := 0; dy < rowH; dy++ {
					img.SetRGBA(x, ry+dy, rowBg)
				}
			}
		}

		// Position with color coding
		posColor := white
		if c.Pos == "1" {
			posColor = yellow
		}

		// Truncate name
		name := c.Name
		if len(name) > 18 {
			name = name[:18]
		}

		gap := c.Gap
		if gap == "" {
			gap = "-"
		}

		drawString(img, face, padX, ry+rowH-6, c.Pos, posColor)
		drawString(img, face, padX+colPos, ry+rowH-6, c.Number, white)
		drawString(img, face, padX+colPos+colNum, ry+rowH-6, name, white)
		drawString(img, face, padX+colPos+colNum+colName, ry+rowH-6, gap, green)
	}

	// Write to temp file then rename (atomic)
	tmp := o.pngPath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := png.Encode(f, img); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	return os.Rename(tmp, o.pngPath)
}

func drawString(img *image.RGBA, face font.Face, x, y int, s string, col color.RGBA) {
	d := &font.Drawer{
		Dst:  img,
		Src:  image.NewUniform(col),
		Face: face,
		Dot:  fixed.Point26_6{X: fixed.I(x), Y: fixed.I(y)},
	}
	d.DrawString(s)
}
