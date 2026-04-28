package overlay

import (
	"encoding/json"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"log"
	"strings"
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
	Laps        int          `json:"ls"`    // laps completed by leader
	LapsToGo    int          `json:"lsTg"`  // laps remaining
	RaceName    string       `json:"rnNam"` // session/race name
	RaceTime    string       `json:"rcTm"`  // race elapsed time
	EventName   string       `json:"eNam"`  // event name
}

// Format controls the overlay layout style.
const (
	FormatFull      = "full"      // P, #, Name, Laps, Gap (wide, default 10 rows)
	FormatCondensed = "condensed" // P, #, "J. Doe", Gap (narrow left-side tower, up to 20 rows)
	FormatMinimal   = "minimal"   // P, #, Gap (ultra-compact)
)

// Overlay polls a MYLAPS live timing session and renders a PNG timing tower.
type Overlay struct {
	mu          sync.RWMutex
	eventID     string
	sessionID   string
	apiBase     string
	pngPath     string
	competitors []Competitor
	sessionName string
	laps        int
	lapsToGo    int
	raceTime    string
	format      string
	maxRows     int
	scale       int
	interval    time.Duration
	stopCh      chan struct{}
	wg          sync.WaitGroup
}

// Config for creating an overlay.
type Config struct {
	EventID   string
	SessionID string // if empty, uses /active endpoint
	PNGPath   string // where to write the overlay PNG
	Format    string // "full", "condensed", "minimal" (default "full")
	MaxRows   int    // max competitors to show (default 10)
	Scale     int    // render scale factor (default 1, use 2 for 1080p)
	Interval  time.Duration
}

func New(cfg Config) *Overlay {
	if cfg.Format == "" {
		cfg.Format = FormatFull
	}
	if cfg.MaxRows == 0 {
		switch cfg.Format {
		case FormatCondensed:
			cfg.MaxRows = 20
		default:
			cfg.MaxRows = 10
		}
	}
	if cfg.Interval == 0 {
		cfg.Interval = 4 * time.Second
	}
	if cfg.Scale < 1 {
		cfg.Scale = 1
	}
	return &Overlay{
		eventID:   cfg.EventID,
		sessionID: cfg.SessionID,
		apiBase:   "https://lt-api.speedhive.com/api",
		pngPath:   cfg.PNGPath,
		format:    cfg.Format,
		maxRows:   cfg.MaxRows,
		scale:     cfg.Scale,
		interval:  cfg.Interval,
		stopCh:    make(chan struct{}),
	}
}

// Start begins polling and rendering.
func (o *Overlay) Start() {
	o.wg.Add(1)
	go func() {
		defer o.wg.Done()
		log.Printf("[overlay] starting initial poll")
		o.poll() // immediate first poll
		ticker := time.NewTicker(o.interval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				o.poll()
			case <-o.stopCh:
				log.Printf("[overlay] stop signal received")
				return
			}
		}
	}()
	log.Printf("[overlay] started: event=%s session=%s interval=%s maxRows=%d pngPath=%s", o.eventID, o.sessionID, o.interval, o.maxRows, o.pngPath)
}

// Stop halts polling.
func (o *Overlay) Stop() {
	log.Printf("[overlay] stopping...")
	close(o.stopCh)
	o.wg.Wait()
	log.Printf("[overlay] stopped")
}

func (o *Overlay) poll() {
	var url string
	if o.sessionID != "" {
		url = fmt.Sprintf("%s/events/%s/sessions/%s/data", o.apiBase, o.eventID, o.sessionID)
	} else {
		url = fmt.Sprintf("%s/events/%s/active", o.apiBase, o.eventID)
	}

	log.Printf("[overlay] poll: GET %s", url)

	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		log.Printf("[overlay] poll: request create error: %v", err)
		return
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Origin", "https://speedhive.mylaps.com")
	req.Header.Set("Referer", "https://speedhive.mylaps.com/")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		log.Printf("[overlay] poll: HTTP error: %v", err)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		log.Printf("[overlay] poll: HTTP %d (non-200)", resp.StatusCode)
		return
	}

	var data sessionResp
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		log.Printf("[overlay] poll: JSON decode error: %v", err)
		return
	}

	log.Printf("[overlay] poll: got %d competitors, laps=%d lapsToGo=%d raceTime=%q raceName=%q",
		len(data.Competitors), data.Laps, data.LapsToGo, data.RaceTime, data.RaceName)

	o.mu.Lock()
	o.competitors = data.Competitors
	if data.RaceName != "" {
		o.sessionName = data.RaceName
	} else if len(o.competitors) > 0 {
		o.sessionName = o.competitors[0].Class
	}
	o.laps = data.Laps
	o.lapsToGo = data.LapsToGo
	o.raceTime = data.RaceTime
	o.mu.Unlock()

	if err := o.render(); err != nil {
		log.Printf("[overlay] poll: render error: %v", err)
	} else {
		log.Printf("[overlay] poll: rendered %d rows to %s", min(len(data.Competitors), o.maxRows), o.pngPath)
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
	laps := o.laps
	lapsToGo := o.lapsToGo
	raceTime := o.raceTime
	format := o.format
	o.mu.RUnlock()

	// Filter out DNS/DNF entries
	comps = filterStatus(comps)

	// Best lap across all competitors (before truncation)
	bestLapTime, bestLapNum := bestLap(comps)

	n := len(comps)
	if n > o.maxRows {
		n = o.maxRows
	}
	if n == 0 {
		return nil
	}

	switch format {
	case FormatCondensed:
		return o.renderCondensed(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum)
	case FormatMinimal:
		return o.renderMinimal(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum)
	default:
		return o.renderFull(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum)
	}
}

// filterStatus removes competitors with DNS/DNF/DSQ/DNQ status.
// Checks both the Pos and Gap fields for status strings.
func filterStatus(comps []Competitor) []Competitor {
	out := make([]Competitor, 0, len(comps))
	for _, c := range comps {
		pos := strings.ToUpper(strings.TrimSpace(c.Pos))
		gap := strings.ToUpper(strings.TrimSpace(c.Gap))
		if pos == "DNS" || pos == "DNF" || pos == "DSQ" || pos == "DNQ" {
			continue
		}
		if gap == "DNS" || gap == "DNF" || gap == "DSQ" || gap == "DNQ" {
			continue
		}
		out = append(out, c)
	}
	return out
}

// bestLap finds the fastest BestLap across all competitors.
// Returns the time string and the rider's name/number. Empty if none.
func bestLap(comps []Competitor) (lap string, rider string) {
	for _, c := range comps {
		t := strings.TrimSpace(c.BestLap)
		if t == "" || t == "-" {
			continue
		}
		if lap == "" || t < lap {
			lap = t
			rider = c.Number
		}
	}
	return
}

// truncGap truncates a gap string to hundredths (2 decimal places).
// "+1.234" → "+1.23", "12.3456" → "12.34", "1 Lap" → "1 Lap"
func truncGap(gap string) string {
	dot := strings.LastIndex(gap, ".")
	if dot < 0 {
		return gap
	}
	decimals := gap[dot+1:]
	if len(decimals) > 2 {
		return gap[:dot+3]
	}
	return gap
}

// condensedName formats "John Smith" → "J. Smith", "JOHN SMITH" → "J. Smith"
func condensedName(full string) string {
	parts := strings.Fields(strings.TrimSpace(full))
	if len(parts) == 0 {
		return ""
	}
	if len(parts) == 1 {
		return titleCase(parts[0])
	}
	initial := strings.ToUpper(string([]rune(parts[0])[0]))
	last := titleCase(parts[len(parts)-1])
	return initial + ". " + last
}

func titleCase(s string) string {
	if len(s) == 0 {
		return s
	}
	r := []rune(strings.ToLower(s))
	r[0] = []rune(strings.ToUpper(string(r[0])))[0]
	return string(r)
}

// renderFull is the original wide format: P, #, Name, Laps, Gap
func (o *Overlay) renderFull(comps []Competitor, sessionName string, laps, lapsToGo int, raceTime string, bestLapTime, bestLapNum string) error {
	face := inconsolata.Bold8x16

	const (
		rowH       = 22
		headerH    = 28
		subHeaderH = 20
		padX       = 8
		charW      = 8
		colPos     = 30
		colNum     = 60
		colName    = 170
		colLaps    = 50
		colGap     = 90
		totalW     = colPos + colNum + colName + colLaps + colGap + padX*2
	)
	n := len(comps)
	totalH := headerH + subHeaderH + rowH*n + 4

	img := image.NewRGBA(image.Rect(0, 0, totalW, totalH))

	bgColor := color.RGBA{0, 0, 0, 200}
	fillRect(img, 0, 0, totalW, totalH, bgColor)

	headerColor := color.RGBA{20, 20, 80, 230}
	fillRect(img, 0, 0, totalW, headerH, headerColor)

	white := color.RGBA{255, 255, 255, 255}
	yellow := color.RGBA{255, 255, 0, 255}
	gray := color.RGBA{180, 180, 180, 255}
	green := color.RGBA{0, 220, 100, 255}
	cyan := color.RGBA{0, 200, 255, 255}

	title := sessionName
	if len(title) > 30 {
		title = title[:30]
	}
	drawString(img, face, padX, headerH-8, title, white)

	lapsInfo := ""
	if lapsToGo > 0 {
		lapsInfo = fmt.Sprintf("Lap %d  %d to go", laps, lapsToGo)
	} else if laps > 0 {
		lapsInfo = fmt.Sprintf("Lap %d", laps)
	}
	if lapsInfo != "" {
		lapsInfoX := totalW - padX - len(lapsInfo)*charW
		drawString(img, face, lapsInfoX, headerH-8, lapsInfo, yellow)
	}

	subHeaderColor := color.RGBA{15, 15, 60, 220}
	fillRect(img, 0, headerH, totalW, subHeaderH, subHeaderColor)
	if raceTime != "" {
		drawString(img, face, padX, headerH+subHeaderH-5, "Race: "+raceTime, cyan)
	}
	if bestLapTime != "" {
		blStr := fmt.Sprintf("Best: %s (#%s)", bestLapTime, bestLapNum)
		blX := totalW - padX - len(blStr)*charW
		drawString(img, face, blX, headerH+subHeaderH-5, blStr, color.RGBA{255, 0, 255, 255})
	}

	y0 := headerH + subHeaderH
	headerRowColor := color.RGBA{40, 40, 40, 200}
	fillRect(img, 0, y0, totalW, rowH, headerRowColor)
	drawString(img, face, padX, y0+rowH-6, "P", gray)
	drawString(img, face, padX+colPos, y0+rowH-6, "#", gray)
	drawString(img, face, padX+colPos+colNum, y0+rowH-6, "Name", gray)
	drawString(img, face, padX+colPos+colNum+colName, y0+rowH-6, "Laps", gray)
	drawString(img, face, padX+colPos+colNum+colName+colLaps, y0+rowH-6, "Gap", gray)

	for i := 0; i < n; i++ {
		c := comps[i]
		ry := y0 + rowH*(i+1)

		if i%2 == 1 {
			fillRect(img, 0, ry, totalW, rowH, color.RGBA{30, 30, 30, 200})
		}

		posColor := white
		if c.Pos == "1" {
			posColor = yellow
		}

		name := c.Name
		if len(name) > 18 {
			name = name[:18]
		}
		gap := c.Gap
		if gap == "" {
			gap = "-"
		}
		lapsStr := fmt.Sprintf("%d", c.Laps)

		drawString(img, face, padX, ry+rowH-6, c.Pos, posColor)
		drawString(img, face, padX+colPos, ry+rowH-6, c.Number, white)
		drawString(img, face, padX+colPos+colNum, ry+rowH-6, name, white)
		drawString(img, face, padX+colPos+colNum+colName, ry+rowH-6, lapsStr, cyan)
		drawString(img, face, padX+colPos+colNum+colName+colLaps, ry+rowH-6, gap, green)
	}

	return o.writePNG(img)
}

// renderCondensed draws a narrow left-side tower: P, #, "J. Doe", Gap
// Header is a separate bar; data rows are compact underneath.
func (o *Overlay) renderCondensed(comps []Competitor, sessionName string, laps, lapsToGo int, raceTime string, bestLapTime, bestLapNum string) error {
	face := inconsolata.Bold8x16

	const (
		rowH      = 22
		titleH    = 26
		bestLapH  = 20
		gapH      = 4 // space between header and data
		padX      = 8
		charW     = 8
		colPos    = 28  // "1" / "20"
		colNum    = 40  // "919"
		colName   = 112 // "J. Giannotto" (14 chars)
		colGap    = 64  // "+1.23"
		dataW     = colPos + colNum + colName + colGap + padX*2
	)
	n := len(comps)

	// Header height: title row + optional best lap row
	headerH := titleH
	if bestLapTime != "" {
		headerH += bestLapH
	}

	// Header width: fit the wider of session name or best lap text
	titleChars := len(sessionName)
	blText := ""
	if bestLapTime != "" {
		blText = fmt.Sprintf("Fastest Lap: %s (#%s)", bestLapTime, bestLapNum)
		if len(blText) > titleChars {
			titleChars = len(blText)
		}
	}
	if titleChars < 20 {
		titleChars = 20
	}
	headerW := titleChars*charW + padX*2
	if headerW < dataW {
		headerW = dataW
	}

	totalH := headerH + gapH + rowH*n + 2

	img := image.NewRGBA(image.Rect(0, 0, headerW, totalH))

	// Transparent base (header may be wider than data)
	fillRect(img, 0, 0, headerW, totalH, color.RGBA{0, 0, 0, 0})

	// Header bar — dark blue, full width
	headerColor := color.RGBA{15, 18, 60, 245}
	fillRect(img, 0, 0, headerW, headerH, headerColor)
	// Gold accent line under header
	fillRect(img, 0, headerH-2, headerW, 2, color.RGBA{200, 170, 0, 255})

	white := color.RGBA{255, 255, 255, 255}
	yellow := color.RGBA{255, 220, 40, 255}
	green := color.RGBA{0, 210, 90, 255}
	numColor := color.RGBA{220, 220, 220, 255}

	// Title row
	drawString(img, face, padX, titleH-8, sessionName, white)
	// Best lap row (below title)
	if bestLapTime != "" {
		drawString(img, face, padX, titleH+bestLapH-6, blText, color.RGBA{255, 0, 255, 255})
	}

	// Data rows — left-aligned, narrower than header
	dataTop := headerH + gapH
	for i := 0; i < n; i++ {
		c := comps[i]
		ry := dataTop + rowH*i

		// Alternating row backgrounds
		if i%2 == 0 {
			fillRect(img, 0, ry, dataW, rowH, color.RGBA{18, 22, 50, 230})
		} else {
			fillRect(img, 0, ry, dataW, rowH, color.RGBA{12, 15, 38, 230})
		}
		// Thin separator line
		fillRect(img, 0, ry+rowH-1, dataW, 1, color.RGBA{40, 45, 70, 180})

		posColor := yellow
		if c.Pos == "1" {
			posColor = color.RGBA{255, 215, 0, 255}
		}

		name := condensedName(c.Name)
		if len(name) > 13 {
			name = name[:13]
		}

		gap := truncGap(c.Gap)
		if gap == "" {
			gap = "-"
		}
		if len(gap) > 7 {
			gap = gap[:7]
		}

		textY := ry + rowH - 5
		drawString(img, face, padX, textY, c.Pos, posColor)
		drawString(img, face, padX+colPos, textY, c.Number, numColor)
		drawString(img, face, padX+colPos+colNum, textY, name, white)
		drawString(img, face, padX+colPos+colNum+colName, textY, gap, green)
	}

	return o.writePNG(img)
}

// renderMinimal draws an ultra-compact tower: P, #, Gap
func (o *Overlay) renderMinimal(comps []Competitor, sessionName string, laps, lapsToGo int, raceTime string, bestLapTime, bestLapNum string) error {
	face := inconsolata.Bold8x16

	const (
		rowH   = 18
		padX   = 6
		colPos = 24
		colNum = 40
		colGap = 64
		totalW = colPos + colNum + colGap + padX*2
	)
	n := len(comps)
	totalH := rowH*n + 2

	img := image.NewRGBA(image.Rect(0, 0, totalW, totalH))

	bgColor := color.RGBA{0, 0, 0, 200}
	fillRect(img, 0, 0, totalW, totalH, bgColor)

	white := color.RGBA{255, 255, 255, 255}
	yellow := color.RGBA{255, 255, 0, 255}
	green := color.RGBA{0, 220, 100, 255}
	cyan := color.RGBA{0, 200, 255, 255}

	for i := 0; i < n; i++ {
		c := comps[i]
		ry := rowH * i

		if i%2 == 1 {
			fillRect(img, 0, ry, totalW, rowH, color.RGBA{25, 25, 25, 200})
		}

		posColor := white
		if c.Pos == "1" {
			posColor = yellow
		}

		gap := c.Gap
		if gap == "" {
			gap = "-"
		}
		if len(gap) > 7 {
			gap = gap[:7]
		}

		drawString(img, face, padX, ry+rowH-4, c.Pos, posColor)
		drawString(img, face, padX+colPos, ry+rowH-4, c.Number, cyan)
		drawString(img, face, padX+colPos+colNum, ry+rowH-4, gap, green)
	}

	return o.writePNG(img)
}

func fillRect(img *image.RGBA, x0, y0, w, h int, c color.RGBA) {
	for y := y0; y < y0+h; y++ {
		for x := x0; x < x0+w; x++ {
			img.SetRGBA(x, y, c)
		}
	}
}

func (o *Overlay) writePNG(img *image.RGBA) error {
	out := img
	if o.scale > 1 {
		out = scaleUp(img, o.scale)
	}
	tmp := o.pngPath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	if err := png.Encode(f, out); err != nil {
		f.Close()
		os.Remove(tmp)
		return err
	}
	f.Close()
	return os.Rename(tmp, o.pngPath)
}

// scaleUp performs nearest-neighbor upscaling by the given factor.
func scaleUp(src *image.RGBA, factor int) *image.RGBA {
	b := src.Bounds()
	w, h := b.Dx()*factor, b.Dy()*factor
	dst := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := 0; y < h; y++ {
		sy := y / factor
		for x := 0; x < w; x++ {
			sx := x / factor
			dst.SetRGBA(x, y, src.RGBAAt(sx+b.Min.X, sy+b.Min.Y))
		}
	}
	return dst
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
