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
	"strconv"
	"strings"
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

// sessionResp is the raw MYLAPS live timing API response.
type sessionResp struct {
	Competitors []Competitor `json:"l"`
	Laps        int          `json:"ls"`    // laps completed by leader
	LapsToGo    int          `json:"lsTg"`  // laps remaining
	RaceName    string       `json:"rnNam"` // session/race name
	RaceTime    string       `json:"rcTm"`  // race elapsed time
	EventName   string       `json:"eNam"`  // event name
}

// resultsResp is the EventResults API response for /sessions/{id}/classification.
type resultsResp struct {
	Type    string `json:"type"`
	BestLap struct {
		Name      string  `json:"name"`
		LapNumber int     `json:"lapNumber"`
		LapTime   string  `json:"lapTime"`
		Speed     float64 `json:"speed"`
	} `json:"bestLap"`
	Rows []resultsRow `json:"rows"`
}

type resultsRow struct {
	Name         string `json:"name"`
	Position     int    `json:"position"`
	StartNumber  string `json:"startNumber"`
	BestTime     string `json:"bestTime"`
	NumberOfLaps int    `json:"numberOfLaps"`
	TotalTime    string `json:"totalTime"`
	ResultClass  string `json:"resultClass"`
	Status       string `json:"status"`
	Difference   struct {
		LapsBehind     int    `json:"lapsBehind"`
		TimeDifference string `json:"timeDifference"`
	} `json:"difference"`
}

// resultsSessionMeta is the session metadata from the EventResults API.
type resultsSessionMeta struct {
	ID   int    `json:"id"`
	Name string `json:"name"`
}

// Format controls the overlay layout style.
const (
	FormatFull           = "full"           // P, #, Name, Laps, Gap (wide, default 10 rows)
	FormatCondensed      = "condensed"      // P, #, "J. Doe", Gap (narrow left-side tower, up to 20 rows)
	FormatCondensedNoGap = "condensed-nogap" // P, #, "J. Doe" (no gap column)
	FormatShort          = "short"          // P, #, "J. Doe", Gap (3-letter last name)
	FormatShortNoGap     = "short-nogap"    // P, #, "J. Doe" (3-letter last name, no gap)
	FormatMinimal        = "minimal"        // P, #, Gap (ultra-compact)
)

// Style controls the visual appearance of the overlay.
// Zero values use defaults.
type Style struct {
	// Colors (RGBA hex strings like "#0F123CAA", parsed to color.RGBA)
	HeaderBg     string `json:"header_bg"`      // header bar background
	AccentColor  string `json:"accent_color"`   // accent line under header
	RowBgEven    string `json:"row_bg_even"`     // even row background
	RowBgOdd     string `json:"row_bg_odd"`      // odd row background
	RowSeparator string `json:"row_separator"`   // thin line between rows
	TextColor    string `json:"text_color"`      // main text (name) color
	PosColor     string `json:"pos_color"`       // position number color
	P1Color      string `json:"p1_color"`        // P1 position color
	NumColor     string `json:"num_color"`       // car number color
	GapColor     string `json:"gap_color"`       // gap text color
	BestLapColor string `json:"best_lap_color"`  // best lap info color
	LapInfoColor string `json:"lap_info_color"`  // lap count info color

	// Sizing
	RowHeight    int `json:"row_height"`     // row height in pixels (default 22)
	HeaderHeight int `json:"header_height"`  // header/title height (default 26)
	PadX         int `json:"pad_x"`          // left padding (default 8)
	PadRight     int `json:"pad_right"`      // right padding after last column (default 0)
	Opacity      int `json:"opacity"`        // row background opacity 0-255 (default 230)
	ColPosW      int `json:"col_pos_w"`      // position column width in pixels (default 28)
	ColNumW      int `json:"col_num_w"`      // number column width in pixels (default 40)
	ColNameW     int `json:"col_name_w"`     // name column width in pixels (default 56)
	ColGapW      int `json:"col_gap_w"`      // gap column width in pixels (default 55)

	// Element position offsets (pixels, can be negative)
	FlagOffsetX    int `json:"flag_offset_x"`     // flag box X offset from default
	FlagOffsetY    int `json:"flag_offset_y"`     // flag box Y offset from default
	LapInfoOffsetX int `json:"lap_info_offset_x"` // lap info box X offset from default
	LapInfoOffsetY int `json:"lap_info_offset_y"` // lap info box Y offset from default
	BestLapOffsetX int `json:"best_lap_offset_x"` // best lap text X offset from default
	BestLapOffsetY int `json:"best_lap_offset_y"` // best lap text Y offset from default
	TowerOffsetX   int `json:"tower_offset_x"`    // data rows X offset from default
	TowerOffsetY   int `json:"tower_offset_y"`    // data rows Y offset from default
}

// DefaultStyle returns the default dark-blue racing style.
func DefaultStyle() Style {
	return Style{
		HeaderBg:     "#0F123CF5",
		AccentColor:  "#C8AA00FF",
		RowBgEven:    "#121632",
		RowBgOdd:     "#0C0F26",
		RowSeparator: "#282D46B4",
		TextColor:    "#FFFFFFFF",
		PosColor:     "#FFDC28FF",
		P1Color:      "#FFD700FF",
		NumColor:     "#DCDCDCFF",
		GapColor:     "#00D25AFF",
		BestLapColor: "#FF00FFFF",
		LapInfoColor: "#FFFFFFFF",
		RowHeight:    22,
		HeaderHeight: 26,
		PadX:         8,
		PadRight:     0,
		Opacity:      230,
		ColPosW:      23,
		ColNumW:      35,
		ColNameW:     56,
		ColGapW:      55,
		FlagOffsetX:  5,
	}
}

// styleColor parses a hex color string to color.RGBA.
// Supports "#RRGGBB", "#RRGGBBAA", or returns fallback.
func styleColor(hex string, fallback color.RGBA) color.RGBA {
	hex = strings.TrimPrefix(hex, "#")
	if len(hex) == 6 {
		hex += "FF"
	}
	if len(hex) != 8 {
		return fallback
	}
	r, _ := strconv.ParseUint(hex[0:2], 16, 8)
	g, _ := strconv.ParseUint(hex[2:4], 16, 8)
	b, _ := strconv.ParseUint(hex[4:6], 16, 8)
	a, _ := strconv.ParseUint(hex[6:8], 16, 8)
	return color.RGBA{uint8(r), uint8(g), uint8(b), uint8(a)}
}

// resolved returns the style with all colors parsed, using defaults for empty values.
func (s Style) resolved() resolvedStyle {
	d := DefaultStyle()
	rs := resolvedStyle{
		headerBg:     styleColor(or(s.HeaderBg, d.HeaderBg), color.RGBA{15, 18, 60, 245}),
		accentColor:  styleColor(or(s.AccentColor, d.AccentColor), color.RGBA{200, 170, 0, 255}),
		rowBgEven:    styleColor(or(s.RowBgEven, d.RowBgEven), color.RGBA{18, 22, 50, 230}),
		rowBgOdd:     styleColor(or(s.RowBgOdd, d.RowBgOdd), color.RGBA{12, 15, 38, 230}),
		rowSeparator: styleColor(or(s.RowSeparator, d.RowSeparator), color.RGBA{40, 45, 70, 180}),
		textColor:    styleColor(or(s.TextColor, d.TextColor), color.RGBA{255, 255, 255, 255}),
		posColor:     styleColor(or(s.PosColor, d.PosColor), color.RGBA{255, 220, 40, 255}),
		p1Color:      styleColor(or(s.P1Color, d.P1Color), color.RGBA{255, 215, 0, 255}),
		numColor:     styleColor(or(s.NumColor, d.NumColor), color.RGBA{220, 220, 220, 255}),
		gapColor:     styleColor(or(s.GapColor, d.GapColor), color.RGBA{0, 210, 90, 255}),
		bestLapColor: styleColor(or(s.BestLapColor, d.BestLapColor), color.RGBA{255, 0, 255, 255}),
		lapInfoColor: styleColor(or(s.LapInfoColor, d.LapInfoColor), color.RGBA{255, 255, 255, 255}),
		rowHeight:    orInt(s.RowHeight, d.RowHeight),
		headerHeight: orInt(s.HeaderHeight, d.HeaderHeight),
		padX:         orInt(s.PadX, d.PadX),
		padRight:     s.PadRight, // 0 is valid default
		opacity:      orInt(s.Opacity, d.Opacity),
		colPosW:      orInt(s.ColPosW, d.ColPosW),
		colNumW:      orInt(s.ColNumW, d.ColNumW),
		colNameW:     orInt(s.ColNameW, d.ColNameW),
		colGapW:      orInt(s.ColGapW, d.ColGapW),
		flagOffsetX:    s.FlagOffsetX,
		flagOffsetY:    s.FlagOffsetY,
		lapInfoOffsetX: s.LapInfoOffsetX,
		lapInfoOffsetY: s.LapInfoOffsetY,
		bestLapOffsetX: s.BestLapOffsetX,
		bestLapOffsetY: s.BestLapOffsetY,
		towerOffsetX:   s.TowerOffsetX,
		towerOffsetY:   s.TowerOffsetY,
	}
	// Apply opacity override to row backgrounds
	if s.Opacity > 0 {
		rs.rowBgEven.A = uint8(rs.opacity)
		rs.rowBgOdd.A = uint8(rs.opacity)
	}
	return rs
}

type resolvedStyle struct {
	headerBg, accentColor                      color.RGBA
	rowBgEven, rowBgOdd, rowSeparator          color.RGBA
	textColor, posColor, p1Color, numColor     color.RGBA
	gapColor, bestLapColor, lapInfoColor       color.RGBA
	rowHeight, headerHeight, padX, padRight, opacity int
	colPosW, colNumW, colNameW, colGapW              int
	flagOffsetX, flagOffsetY                         int
	lapInfoOffsetX, lapInfoOffsetY                   int
	bestLapOffsetX, bestLapOffsetY                   int
	towerOffsetX, towerOffsetY                       int
}

func or(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func orInt(a, b int) int {
	if a != 0 {
		return a
	}
	return b
}

// Overlay polls a MYLAPS live timing session and renders a PNG timing tower.
type Overlay struct {
	mu          sync.RWMutex
	eventID     string
	sessionID   string
	apiBase     string
	resultsBase string // eventresults-api base URL
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
	titleOverride string
	flagStatus    string
	style         Style
	useResultsAPI bool // true when using /sessions/{id} URL format
	paused        bool // true during ad playback — suppress rendering
	stopCh      chan struct{}
	wg          sync.WaitGroup
}

// Config for creating an overlay.
type Config struct {
	EventID    string
	SessionID  string // if empty, uses /active endpoint
	PNGPath    string // where to write the overlay PNG
	Format     string // "full", "condensed", "minimal" (default "full")
	MaxRows    int    // max competitors to show (default 10)
	Scale      int    // render scale factor (default 1, use 2 for 1080p)
	Interval   time.Duration
	Title      string // custom title override (replaces SpeedHive session name)
	FlagStatus string // flag status text, e.g. "Red Flag" (empty = no flag shown)
}

func New(cfg Config) *Overlay {
	if cfg.Format == "" {
		cfg.Format = FormatFull
	}
	if cfg.MaxRows == 0 {
		cfg.MaxRows = 25
	}
	if cfg.Interval == 0 {
		cfg.Interval = 4 * time.Second
	}
	if cfg.Scale < 1 {
		cfg.Scale = 1
	}
	return &Overlay{
		eventID:       cfg.EventID,
		sessionID:     cfg.SessionID,
		apiBase:       "https://lt-api.speedhive.com/api",
		resultsBase:   "https://eventresults-api.speedhive.com/api/v0.2.3/eventresults",
		pngPath:       cfg.PNGPath,
		format:        cfg.Format,
		maxRows:       cfg.MaxRows,
		scale:         cfg.Scale,
		interval:      cfg.Interval,
		titleOverride: cfg.Title,
		flagStatus:    cfg.FlagStatus,
		useResultsAPI: cfg.EventID == "" && cfg.SessionID != "",
		stopCh:        make(chan struct{}),
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

// Pause suppresses overlay rendering (e.g. during ad playback).
func (o *Overlay) Pause() {
	o.mu.Lock()
	o.paused = true
	o.mu.Unlock()
	log.Printf("[overlay] paused (ad playback)")
}

// Resume re-enables overlay rendering after ads finish.
func (o *Overlay) Resume() {
	o.mu.Lock()
	o.paused = false
	o.mu.Unlock()
	log.Printf("[overlay] resumed")
}

// Stop halts polling.
func (o *Overlay) Stop() {
	log.Printf("[overlay] stopping...")
	close(o.stopCh)
	o.wg.Wait()
	log.Printf("[overlay] stopped")
}

// SetFlagStatus updates the flag status text and triggers a re-render.
func (o *Overlay) SetFlagStatus(status string) {
	o.mu.Lock()
	o.flagStatus = status
	o.mu.Unlock()
	// Re-render immediately with new flag status
	if err := o.render(); err != nil {
		log.Printf("[overlay] SetFlagStatus re-render error: %v", err)
	}
}

// Update changes overlay settings without restarting the poll loop.
func (o *Overlay) Update(format string, maxRows, scale int, title string) {
	o.mu.Lock()
	if format != "" {
		o.format = format
	}
	if maxRows > 0 {
		o.maxRows = maxRows
	}
	if scale > 0 {
		o.scale = scale
	}
	o.titleOverride = title
	o.mu.Unlock()
	log.Printf("[overlay] Update: format=%s maxRows=%d scale=%d title=%q", format, maxRows, scale, title)
	if err := o.render(); err != nil {
		log.Printf("[overlay] Update re-render error: %v", err)
	}
}

func (o *Overlay) poll() {
	if o.useResultsAPI {
		o.pollResults()
	} else {
		o.pollLiveTiming()
	}
}

func (o *Overlay) pollResults() {
	classURL := fmt.Sprintf("%s/sessions/%s/classification", o.resultsBase, o.sessionID)
	log.Printf("[overlay] pollResults: GET %s", classURL)

	data, err := o.fetchJSON(classURL)
	if err != nil {
		log.Printf("[overlay] pollResults: %v", err)
		return
	}

	var results resultsResp
	if err := json.Unmarshal(data, &results); err != nil {
		log.Printf("[overlay] pollResults: JSON decode error: %v", err)
		return
	}

	// Fetch session name if not already set and no title override
	o.mu.RLock()
	needName := o.sessionName == "" && o.titleOverride == ""
	o.mu.RUnlock()
	if needName {
		metaURL := fmt.Sprintf("%s/sessions/%s", o.resultsBase, o.sessionID)
		if metaData, err := o.fetchJSON(metaURL); err == nil {
			var meta resultsSessionMeta
			if json.Unmarshal(metaData, &meta) == nil && meta.Name != "" {
				o.mu.Lock()
				o.sessionName = meta.Name
				o.mu.Unlock()
			}
		}
	}

	// Convert results rows to Competitor format
	comps := make([]Competitor, 0, len(results.Rows))
	for _, r := range results.Rows {
		if r.Status != "Normal" {
			continue
		}
		gap := ""
		if r.Difference.LapsBehind > 0 {
			gap = fmt.Sprintf("%d Lap", r.Difference.LapsBehind)
			if r.Difference.LapsBehind > 1 {
				gap += "s"
			}
		} else if r.Difference.TimeDifference != "" && r.Difference.TimeDifference != "00.000" {
			gap = "+" + r.Difference.TimeDifference
		}
		comps = append(comps, Competitor{
			Pos:     fmt.Sprintf("%d", r.Position),
			Number:  r.StartNumber,
			Name:    r.Name,
			BestLap: r.BestTime,
			Gap:     gap,
			Laps:    r.NumberOfLaps,
			Class:   r.ResultClass,
		})
	}

	log.Printf("[overlay] pollResults: got %d competitors", len(comps))

	o.mu.Lock()
	o.competitors = comps
	if len(comps) > 0 && o.sessionName == "" {
		o.sessionName = comps[0].Class
	}
	if len(comps) > 0 {
		o.laps = comps[0].Laps
	}
	o.mu.Unlock()

	if err := o.render(); err != nil {
		log.Printf("[overlay] pollResults: render error: %v", err)
	} else {
		log.Printf("[overlay] pollResults: rendered %d rows to %s", min(len(comps), o.maxRows), o.pngPath)
	}
}

func (o *Overlay) fetchJSON(url string) ([]byte, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, fmt.Errorf("request create error: %w", err)
	}
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Origin", "https://speedhive.mylaps.com")
	req.Header.Set("Referer", "https://speedhive.mylaps.com/")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP error: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		io.Copy(io.Discard, resp.Body)
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("read error: %w", err)
	}
	return body, nil
}

func (o *Overlay) pollLiveTiming() {
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
	if o.paused {
		o.mu.RUnlock()
		return nil // suppress rendering during ad playback
	}
	comps := o.competitors
	sessionName := o.sessionName
	if o.titleOverride != "" {
		sessionName = o.titleOverride
	}
	laps := o.laps
	lapsToGo := o.lapsToGo
	raceTime := o.raceTime
	format := o.format
	flagStatus := o.flagStatus
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
		return o.renderCondensed(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum, flagStatus)
	case FormatCondensedNoGap:
		return o.renderCondensedVariant(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum, flagStatus, false, condensedName, 13, 112)
	case FormatShort:
		return o.renderCondensedVariant(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum, flagStatus, true, shortName, 7, 64)
	case FormatShortNoGap:
		return o.renderCondensedVariant(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum, flagStatus, false, shortName, 7, 64)
	case FormatMinimal:
		return o.renderMinimal(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum, flagStatus)
	default:
		return o.renderFull(comps[:n], sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum, flagStatus)
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
// For gaps containing ":" (over 1 minute), decimals are removed entirely.
// "+1.234" → "+1.23", "+1:23.456" → "+1:23", "1 Lap" → "1 Lap"
func truncGap(gap string) string {
	dot := strings.LastIndex(gap, ".")
	if dot < 0 {
		return gap
	}
	// Over 1 minute: drop all decimals
	if strings.Contains(gap, ":") {
		return gap[:dot]
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
	return initial + "." + last
}

// shortName formats "John Smith" → "J.Smi", "JOHN SMITH" → "J.Smi" (3-letter last name)
func shortName(full string) string {
	parts := strings.Fields(strings.TrimSpace(full))
	if len(parts) == 0 {
		return ""
	}
	if len(parts) == 1 {
		tc := titleCase(parts[0])
		if len([]rune(tc)) > 3 {
			return string([]rune(tc)[:3])
		}
		return tc
	}
	initial := strings.ToUpper(string([]rune(parts[0])[0]))
	last := titleCase(parts[len(parts)-1])
	runes := []rune(last)
	if len(runes) > 3 {
		last = string(runes[:3])
	}
	return initial + "." + last
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
func (o *Overlay) renderFull(comps []Competitor, sessionName string, laps, lapsToGo int, raceTime string, bestLapTime, bestLapNum string, flagStatus string) error {
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
		towerW     = colPos + colNum + colName + colLaps + colGap + padX*2
		flagGap    = 12
		flagPadX   = 10
		flagPadY   = 6
	)
	n := len(comps)
	totalH := headerH + subHeaderH + rowH*n + 4

	// Calculate flag box dimensions
	flagBoxW := 0
	flagBoxH := 0
	if flagStatus != "" {
		flagBoxW = len(flagStatus)*charW + flagPadX*2
		flagBoxH = 16 + flagPadY*2
	}

	totalW := towerW
	if flagBoxW > 0 {
		totalW = towerW + flagGap + flagBoxW
	}

	img := image.NewRGBA(image.Rect(0, 0, totalW, totalH))

	bgColor := color.RGBA{0, 0, 0, 200}
	fillRect(img, 0, 0, towerW, totalH, bgColor)

	headerColor := color.RGBA{20, 20, 80, 230}
	fillRect(img, 0, 0, towerW, headerH, headerColor)

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

	// Flag status — standalone box to the right of the tower, vertically below header
	if flagStatus != "" {
		flagX := towerW + flagGap
		flagY := headerH + subHeaderH + 4 // same gap as between title and rows
		flagBg := flagColor(flagStatus)
		flagText := strings.ToUpper(flagStatus)
		flagTextW := len(flagText)*charW + flagPadX*2
		if flagTextW > flagBoxW {
			flagBoxW = flagTextW
		}
		fillRect(img, flagX, flagY, flagBoxW, flagBoxH, flagBg)
		textColor := white
		if strings.Contains(strings.ToLower(flagStatus), "yellow") {
			textColor = color.RGBA{0, 0, 0, 255}
		}
		drawString(img, face, flagX+flagPadX, flagY+flagBoxH-flagPadY-2, flagText, textColor)
	}

	lapsInfo := ""
	if lapsToGo > 0 {
		lapsInfo = fmt.Sprintf("Lap %d  %d to go", laps, lapsToGo)
	} else if laps > 0 {
		lapsInfo = fmt.Sprintf("Lap %d", laps)
	}
	if lapsInfo != "" {
		lapsInfoX := towerW - padX - len(lapsInfo)*charW
		drawString(img, face, lapsInfoX, headerH-8, lapsInfo, yellow)
	}

	subHeaderColor := color.RGBA{15, 15, 60, 220}
	fillRect(img, 0, headerH, towerW, subHeaderH, subHeaderColor)
	if raceTime != "" {
		drawString(img, face, padX, headerH+subHeaderH-5, "Race: "+raceTime, cyan)
	}
	if bestLapTime != "" {
		blStr := fmt.Sprintf("Best: %s (#%s)", bestLapTime, bestLapNum)
		blX := towerW - padX - len(blStr)*charW
		drawString(img, face, blX, headerH+subHeaderH-5, blStr, color.RGBA{255, 0, 255, 255})
	}

	y0 := headerH + subHeaderH
	headerRowColor := color.RGBA{40, 40, 40, 200}
	fillRect(img, 0, y0, towerW, rowH, headerRowColor)
	drawString(img, face, padX, y0+rowH-6, "P", gray)
	drawString(img, face, padX+colPos, y0+rowH-6, "#", gray)
	drawString(img, face, padX+colPos+colNum, y0+rowH-6, "Name", gray)
	drawString(img, face, padX+colPos+colNum+colName, y0+rowH-6, "Laps", gray)
	drawString(img, face, padX+colPos+colNum+colName+colLaps, y0+rowH-6, "Gap", gray)

	for i := 0; i < n; i++ {
		c := comps[i]
		ry := y0 + rowH*(i+1)

		if i%2 == 1 {
			fillRect(img, 0, ry, towerW, rowH, color.RGBA{30, 30, 30, 200})
		}

		posColor := white
		if c.Pos == "1" {
			posColor = yellow
		}

		name := c.Name
		if len(name) > 18 {
			name = name[:18]
		}
		gap := truncGap(c.Gap)
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
func (o *Overlay) renderCondensed(comps []Competitor, sessionName string, laps, lapsToGo int, raceTime string, bestLapTime, bestLapNum string, flagStatus string) error {
	return o.renderCondensedVariant(comps, sessionName, laps, lapsToGo, raceTime, bestLapTime, bestLapNum, flagStatus, true, condensedName, 13, 112)
}

// renderCondensedVariant is the shared implementation for condensed-style formats.
// showGap controls whether the gap column is rendered.
// nameFn formats competitor names. maxNameLen truncates names. colNameW is the column pixel width for names.
func (o *Overlay) renderCondensedVariant(comps []Competitor, sessionName string, laps, lapsToGo int, raceTime string, bestLapTime, bestLapNum string, flagStatus string, showGap bool, nameFn func(string) string, maxNameLen int, colNameW int) error {
	face := inconsolata.Bold8x16
	st := o.style.resolved()

	rowH := st.rowHeight
	titleH := st.headerHeight
	padX := st.padX
	const (
		bestLapH  = 20
		gapH      = 4
		charW     = 8
		boxPadX   = 10
	)
	colPos := st.colPosW
	colNum := st.colNumW
	colGap := st.colGapW
	colName := st.colNameW
	dataW := colPos + colNum + colName + padX + st.padRight
	if showGap {
		dataW += colGap
	}
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

	// Build lap info text
	lapText := ""
	totalLaps := laps + lapsToGo
	if lapsToGo == 1 {
		lapText = "FINAL LAP"
	} else if lapsToGo > 0 && lapsToGo <= 5 {
		lapText = fmt.Sprintf("%d LAPS TO GO", lapsToGo)
	} else if lapsToGo > 5 {
		lapText = fmt.Sprintf("Lap %d of %d", laps, totalLaps)
	} else if laps > 0 {
		lapText = fmt.Sprintf("Lap %d", laps)
	}

	// Lap and flag boxes: same height as titleH, inline horizontally to the right of header
	lapBoxW := 0
	if lapText != "" {
		lapBoxW = len(lapText)*charW + boxPadX*2
	}

	flagBoxW := 0
	isCheckered := strings.Contains(strings.ToLower(flagStatus), "checker")
	if flagStatus != "" {
		if isCheckered {
			flagText := "CHECKERED"
			flagBoxW = len(flagText)*charW + boxPadX*2
		} else {
			flagText := strings.ToUpper(flagStatus)
			flagBoxW = len(flagText)*charW + boxPadX*2
		}
	}

	// Image width: header + gap + lap box + gap + flag box (with offsets)
	imgW := headerW
	if lapBoxW > 0 {
		imgW += gapH + lapBoxW
	}
	if flagBoxW > 0 {
		imgW += gapH + flagBoxW
	}
	// Expand image to fit offsets
	extraW := 0
	if st.flagOffsetX > 0 {
		extraW = max(extraW, st.flagOffsetX)
	}
	if st.lapInfoOffsetX > 0 {
		extraW = max(extraW, st.lapInfoOffsetX)
	}
	if st.towerOffsetX > 0 {
		extraW = max(extraW, st.towerOffsetX)
	}
	imgW += extraW

	extraH := 0
	if st.flagOffsetY > 0 {
		extraH = max(extraH, st.flagOffsetY)
	}
	if st.towerOffsetY > 0 {
		extraH = max(extraH, st.towerOffsetY)
	}
	if st.bestLapOffsetY > 0 {
		extraH = max(extraH, st.bestLapOffsetY)
	}

	totalH := headerH + gapH + rowH*n + 2 + extraH

	img := image.NewRGBA(image.Rect(0, 0, imgW, totalH))

	// Transparent base (header may be wider than data)
	fillRect(img, 0, 0, imgW, totalH, color.RGBA{0, 0, 0, 0})

	// Header bar — dark blue, full width
	fillRect(img, 0, 0, headerW, headerH, st.headerBg)
	// Gold accent line under header
	fillRect(img, 0, headerH-2, headerW, 2, st.accentColor)

	white := color.RGBA{255, 255, 255, 255}

	// Title row
	drawString(img, face, padX, titleH-8, sessionName, st.textColor)

	// Right-side boxes: lap and flag inline horizontally, same height as title bar
	curX := headerW + gapH

	// Lap info box
	if lapText != "" {
		lapX := curX + st.lapInfoOffsetX
		lapY := st.lapInfoOffsetY
		fillRect(img, lapX, lapY, lapBoxW, titleH, st.headerBg)
		drawString(img, face, lapX+boxPadX, lapY+titleH-8, lapText, st.lapInfoColor)
		curX += lapBoxW + gapH
	}

	// Flag status box — to the right of lap box, same height
	if flagStatus != "" {
		flagX := curX + st.flagOffsetX
		flagY := st.flagOffsetY
		if isCheckered {
			// Draw checker pattern: alternating black/white squares
			sqSize := titleH / 4
			if sqSize < 3 {
				sqSize = 3
			}
			black := color.RGBA{0, 0, 0, 255}
			for row := 0; row < titleH; row++ {
				for col := 0; col < flagBoxW; col++ {
					if (row/sqSize+col/sqSize)%2 == 0 {
						img.SetRGBA(flagX+col, flagY+row, white)
					} else {
						img.SetRGBA(flagX+col, flagY+row, black)
					}
				}
			}
		} else {
			flagBg := flagColor(flagStatus)
			flagText := strings.ToUpper(flagStatus)
			fillRect(img, flagX, flagY, flagBoxW, titleH, flagBg)
			textColor := white
			if strings.Contains(strings.ToLower(flagStatus), "yellow") {
				textColor = color.RGBA{0, 0, 0, 255}
			}
			drawString(img, face, flagX+boxPadX, flagY+titleH-8, flagText, textColor)
		}
	}

	// Best lap row (below title)
	if bestLapTime != "" {
		blX := padX + st.bestLapOffsetX
		blY := titleH + bestLapH - 6 + st.bestLapOffsetY
		drawString(img, face, blX, blY, blText, st.bestLapColor)
	}

	// Data rows — left-aligned, narrower than header
	dataTop := headerH + gapH + st.towerOffsetY
	towerX := st.towerOffsetX
	for i := 0; i < n; i++ {
		c := comps[i]
		ry := dataTop + rowH*i

		// Alternating row backgrounds
		if i%2 == 0 {
			fillRect(img, towerX, ry, dataW, rowH, st.rowBgEven)
		} else {
			fillRect(img, towerX, ry, dataW, rowH, st.rowBgOdd)
		}
		// Thin separator line
		fillRect(img, towerX, ry+rowH-1, dataW, 1, st.rowSeparator)

		posColor := st.posColor
		if c.Pos == "1" {
			posColor = st.p1Color
		}

		name := nameFn(c.Name)
		if len(name) > maxNameLen {
			name = name[:maxNameLen]
		}

		textY := ry + rowH - 5
		drawString(img, face, towerX+padX, textY, c.Pos, posColor)
		drawString(img, face, towerX+padX+colPos, textY, c.Number, st.numColor)
		drawString(img, face, towerX+padX+colPos+colNum, textY, name, st.textColor)
		if showGap {
			gap := truncGap(c.Gap)
			if gap == "" {
				gap = "-"
			}
			if len(gap) > 7 {
				gap = gap[:7]
			}
			drawString(img, face, towerX+padX+colPos+colNum+colName, textY, gap, st.gapColor)
		}
	}

	return o.writePNG(img)
}

// renderMinimal draws an ultra-compact tower: P, #, Gap
func (o *Overlay) renderMinimal(comps []Competitor, sessionName string, laps, lapsToGo int, raceTime string, bestLapTime, bestLapNum string, flagStatus string) error {
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

		gap := truncGap(c.Gap)
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

// flagColor returns the background color for a given flag status text.
func flagColor(status string) color.RGBA {
	s := strings.ToLower(status)
	switch {
	case strings.Contains(s, "red"):
		return color.RGBA{220, 30, 30, 255}
	case strings.Contains(s, "yellow"):
		return color.RGBA{230, 190, 0, 255}
	case strings.Contains(s, "green"):
		return color.RGBA{30, 160, 50, 255}
	case strings.Contains(s, "checker"):
		return color.RGBA{40, 40, 40, 255}
	default:
		return color.RGBA{220, 30, 30, 255}
	}
}

// RenderPreview renders an overlay with the given parameters and returns PNG bytes.
// This is for dev preview only — it does not write to disk or poll any API.
func RenderPreview(format string, maxRows, scale int, title, flag string, comps []Competitor, laps, lapsToGo int, raceTime string, style ...Style) ([]byte, error) {
	f, err := os.CreateTemp("", "overlay-preview-*.png")
	if err != nil {
		return nil, err
	}
	tmpPath := f.Name()
	f.Close()
	defer os.Remove(tmpPath)

	var s Style
	if len(style) > 0 {
		s = style[0]
	}

	o := &Overlay{
		pngPath:       tmpPath,
		format:        format,
		maxRows:       maxRows,
		scale:         scale,
		titleOverride: title,
		flagStatus:    flag,
		competitors:   comps,
		laps:          laps,
		lapsToGo:      lapsToGo,
		raceTime:      raceTime,
		style:         s,
		stopCh:        make(chan struct{}),
	}
	if err := o.render(); err != nil {
		return nil, err
	}
	return os.ReadFile(tmpPath)
}
