package main

import (
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/dchristiani/media-mtx/internal/overlay"
)

var mockCompetitors = []overlay.Competitor{
	{Pos: "1", Number: "919", Name: "John Giannotto", LastLap: "1:02.345", BestLap: "1:01.234", Gap: "", Laps: 12, Class: "Pro"},
	{Pos: "2", Number: "42", Name: "Mike Thompson", LastLap: "1:02.567", BestLap: "1:01.567", Gap: "+0.333", Laps: 12, Class: "Pro"},
	{Pos: "3", Number: "7", Name: "Alex Rodriguez", LastLap: "1:03.012", BestLap: "1:02.012", Gap: "+0.778", Laps: 12, Class: "Pro"},
	{Pos: "4", Number: "155", Name: "Dan Christiani", LastLap: "1:03.456", BestLap: "1:02.456", Gap: "+1.222", Laps: 12, Class: "Pro"},
	{Pos: "5", Number: "33", Name: "PATRICK O'BRIEN", LastLap: "1:03.890", BestLap: "1:02.890", Gap: "+1.656", Laps: 12, Class: "Pro"},
	{Pos: "6", Number: "88", Name: "Kevin Wu", LastLap: "1:04.123", BestLap: "1:03.123", Gap: "+1.889", Laps: 12, Class: "Am"},
	{Pos: "7", Number: "5", Name: "Sarah McNamara", LastLap: "1:04.567", BestLap: "1:03.567", Gap: "+2.333", Laps: 12, Class: "Am"},
	{Pos: "8", Number: "212", Name: "ROBERTO MARTINEZ GONZALEZ", LastLap: "1:04.890", BestLap: "1:03.890", Gap: "+2.656", Laps: 12, Class: "Am"},
	{Pos: "9", Number: "16", Name: "Tom Baker", LastLap: "1:05.123", BestLap: "1:04.123", Gap: "+2.889", Laps: 12, Class: "Am"},
	{Pos: "10", Number: "77", Name: "JAMES LEE", LastLap: "1:05.456", BestLap: "1:04.456", Gap: "+3.222", Laps: 11, Class: "Am"},
	{Pos: "11", Number: "3", Name: "Chris Ng", LastLap: "1:05.890", BestLap: "1:04.890", Gap: "+3.656", Laps: 11, Class: "Am"},
	{Pos: "12", Number: "101", Name: "David Steinberg", LastLap: "1:06.123", BestLap: "1:05.123", Gap: "+4.889", Laps: 11, Class: "Am"},
	{Pos: "13", Number: "44", Name: "Ryan Park", LastLap: "1:06.567", BestLap: "1:05.567", Gap: "+5.333", Laps: 11, Class: "Nov"},
	{Pos: "14", Number: "9", Name: "EMILY JOHNSON", LastLap: "1:06.890", BestLap: "1:05.890", Gap: "+6.656", Laps: 11, Class: "Nov"},
	{Pos: "15", Number: "222", Name: "Marco Di Lorenzo", LastLap: "1:07.123", BestLap: "1:06.123", Gap: "+8.889", Laps: 11, Class: "Nov"},
	{Pos: "16", Number: "18", Name: "Brian Cox", LastLap: "1:07.456", BestLap: "1:06.456", Gap: "+12.22", Laps: 11, Class: "Nov"},
	{Pos: "17", Number: "55", Name: "ANNA SCHMIDT", LastLap: "1:07.890", BestLap: "1:06.890", Gap: "1 Lap", Laps: 10, Class: "Nov"},
	{Pos: "18", Number: "131", Name: "Pete Vo", LastLap: "1:08.123", BestLap: "1:07.123", Gap: "1 Lap", Laps: 10, Class: "Nov"},
	{Pos: "19", Number: "66", Name: "LUCAS FERNANDEZ", LastLap: "1:08.567", BestLap: "1:07.567", Gap: "2 Laps", Laps: 9, Class: "Nov"},
	{Pos: "20", Number: "200", Name: "Will Chang", LastLap: "1:09.012", BestLap: "1:08.012", Gap: "2 Laps", Laps: 9, Class: "Nov"},
}

var formats = []struct {
	value string
	label string
}{
	{"full", "Full"},
	{"condensed", "Condensed"},
	{"condensed-nogap", "Condensed No Gap"},
	{"short", "Short"},
	{"short-nogap", "Short No Gap"},
	{"minimal", "Minimal"},
}

func main() {
	http.HandleFunc("/", handleIndex)
	http.HandleFunc("/render", handleRender)

	addr := ":9090"
	log.Printf("Overlay preview: http://localhost%s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func handleRender(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	format := q.Get("format")
	if format == "" {
		format = "condensed"
	}
	maxRows, _ := strconv.Atoi(q.Get("rows"))
	if maxRows == 0 {
		maxRows = 20
	}
	scale, _ := strconv.ParseFloat(q.Get("scale"), 64)
	if scale < 1 {
		scale = 1
	}
	title := q.Get("title")
	if title == "" {
		title = "Pro Kart Race 7"
	}
	flag := q.Get("flag")
	laps, _ := strconv.Atoi(q.Get("laps"))
	if laps == 0 {
		laps = 12
	}
	lapsToGo, _ := strconv.Atoi(q.Get("lapstogo"))
	if lapsToGo == 0 && q.Get("lapstogo") == "" {
		lapsToGo = 8
	}
	raceTime := q.Get("racetime")
	if raceTime == "" {
		raceTime = "12:34.56"
	}
	count, _ := strconv.Atoi(q.Get("count"))
	if count == 0 || count > len(mockCompetitors) {
		count = len(mockCompetitors)
	}

	style := overlay.Style{
		HeaderBg:     q.Get("header_bg"),
		AccentColor:  q.Get("accent_color"),
		RowBgEven:    q.Get("row_bg_even"),
		RowBgOdd:     q.Get("row_bg_odd"),
		RowSeparator: q.Get("row_separator"),
		TextColor:    q.Get("text_color"),
		PosColor:     q.Get("pos_color"),
		P1Color:      q.Get("p1_color"),
		NumColor:     q.Get("num_color"),
		GapColor:     q.Get("gap_color"),
		BestLapColor: q.Get("best_lap_color"),
		LapInfoColor: q.Get("lap_info_color"),
	}
	if v, _ := strconv.Atoi(q.Get("row_height")); v > 0 {
		style.RowHeight = v
	}
	if v, _ := strconv.Atoi(q.Get("header_height")); v > 0 {
		style.HeaderHeight = v
	}
	if v, _ := strconv.Atoi(q.Get("pad_x")); v > 0 {
		style.PadX = v
	}
	if v, _ := strconv.Atoi(q.Get("pad_right")); v > 0 {
		style.PadRight = v
	}
	if v, _ := strconv.Atoi(q.Get("col_pos_w")); v > 0 {
		style.ColPosW = v
	}
	if v, _ := strconv.Atoi(q.Get("col_num_w")); v > 0 {
		style.ColNumW = v
	}
	if v, _ := strconv.Atoi(q.Get("col_name_w")); v > 0 {
		style.ColNameW = v
	}
	if v, _ := strconv.Atoi(q.Get("col_gap_w")); v > 0 {
		style.ColGapW = v
	}
	if v, _ := strconv.Atoi(q.Get("opacity")); v > 0 {
		style.Opacity = v
	}

	// Element position offsets (can be negative)
	for _, pair := range []struct {
		key string
		dst *int
	}{
		{"flag_offset_x", &style.FlagOffsetX},
		{"flag_offset_y", &style.FlagOffsetY},
		{"lap_info_offset_x", &style.LapInfoOffsetX},
		{"lap_info_offset_y", &style.LapInfoOffsetY},
		{"best_lap_offset_x", &style.BestLapOffsetX},
		{"best_lap_offset_y", &style.BestLapOffsetY},
		{"tower_offset_x", &style.TowerOffsetX},
		{"tower_offset_y", &style.TowerOffsetY},
	} {
		if s := q.Get(pair.key); s != "" {
			if v, err := strconv.Atoi(s); err == nil {
				*pair.dst = v
			}
		}
	}

	data, err := overlay.RenderPreview(format, maxRows, scale, title, flag, mockCompetitors[:count], laps, lapsToGo, raceTime, style)
	if err != nil {
		log.Printf("[render] ERROR format=%s rows=%d scale=%.1f: %v", format, maxRows, scale, err)
		http.Error(w, err.Error(), 500)
		return
	}

	w.Header().Set("Content-Type", "image/png")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write(data)
}

func handleIndex(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	rows := qd(q, "rows", "20")
	scale := qd(q, "scale", "1")
	title := qd(q, "title", "Pro Kart Race 7")
	flag := q.Get("flag")
	laps := qd(q, "laps", "12")
	lapsToGo := qd(q, "lapstogo", "8")
	raceTime := qd(q, "racetime", "12:34.56")
	bg := qd(q, "bg", "video")
	layout := qd(q, "layout", "grid")
	count := qd(q, "count", "20")
	showFormats := q["fmt"]
	if len(showFormats) == 0 {
		for _, f := range formats {
			showFormats = append(showFormats, f.value)
		}
	}

	// Style defaults
	ds := overlay.DefaultStyle()
	styleFields := []struct {
		key, label, def string
	}{
		{"header_bg", "Header BG", ds.HeaderBg},
		{"accent_color", "Accent", ds.AccentColor},
		{"row_bg_even", "Row Even", ds.RowBgEven},
		{"row_bg_odd", "Row Odd", ds.RowBgOdd},
		{"row_separator", "Separator", ds.RowSeparator},
		{"text_color", "Name", ds.TextColor},
		{"pos_color", "Position", ds.PosColor},
		{"p1_color", "P1", ds.P1Color},
		{"num_color", "Number", ds.NumColor},
		{"gap_color", "Gap", ds.GapColor},
		{"best_lap_color", "Best Lap", ds.BestLapColor},
		{"lap_info_color", "Lap Info", ds.LapInfoColor},
	}
	styleSizing := []struct {
		key, label, def string
		min, max        int
	}{
		{"row_height", "Row H", fmt.Sprintf("%d", ds.RowHeight), 14, 40},
		{"header_height", "Header H", fmt.Sprintf("%d", ds.HeaderHeight), 18, 50},
		{"pad_x", "Pad X", fmt.Sprintf("%d", ds.PadX), 2, 20},
		{"pad_right", "Pad Right", fmt.Sprintf("%d", ds.PadRight), 0, 30},
		{"opacity", "Opacity", fmt.Sprintf("%d", ds.Opacity), 50, 255},
		{"col_pos_w", "Pos Col W", fmt.Sprintf("%d", ds.ColPosW), 16, 60},
		{"col_num_w", "Num Col W", fmt.Sprintf("%d", ds.ColNumW), 24, 80},
		{"col_name_w", "Name Col W", fmt.Sprintf("%d", ds.ColNameW), 24, 200},
		{"col_gap_w", "Gap Col W", fmt.Sprintf("%d", ds.ColGapW), 24, 120},
		{"flag_offset_x", "Flag X", "0", -200, 200},
		{"flag_offset_y", "Flag Y", "0", -200, 200},
		{"lap_info_offset_x", "Lap Info X", "0", -200, 200},
		{"lap_info_offset_y", "Lap Info Y", "0", -200, 200},
		{"best_lap_offset_x", "Best Lap X", "0", -200, 200},
		{"best_lap_offset_y", "Best Lap Y", "0", -200, 200},
		{"tower_offset_x", "Tower X", "0", -200, 200},
		{"tower_offset_y", "Tower Y", "0", -200, 200},
	}

	// Collect current style values
	styleVals := map[string]string{}
	for _, sf := range styleFields {
		styleVals[sf.key] = qd(q, sf.key, sf.def)
	}
	for _, ss := range styleSizing {
		styleVals[ss.key] = qd(q, ss.key, ss.def)
	}

	// Build set
	showSet := map[string]bool{}
	for _, f := range showFormats {
		showSet[f] = true
	}

	bgCSS := "#1a1a2e"
	switch bg {
	case "video":
		bgCSS = "#1a1a2e"
	case "black":
		bgCSS = "#000"
	case "white":
		bgCSS = "#fff"
	case "green":
		bgCSS = "#00b140"
	case "gray":
		bgCSS = "#555"
	case "track":
		bgCSS = "#3a3a3a url('data:image/svg+xml,<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"40\" height=\"40\"><rect width=\"40\" height=\"40\" fill=\"%233a3a3a\"/><circle cx=\"20\" cy=\"20\" r=\"1\" fill=\"%23555\"/></svg>')"
	}

	layoutCSS := "display:flex;flex-wrap:wrap;gap:24px;"
	if layout == "column" {
		layoutCSS = "display:flex;flex-direction:column;gap:16px;max-width:600px;"
	} else if layout == "compare" {
		layoutCSS = "display:grid;grid-template-columns:1fr 1fr;gap:24px;"
	}

	var sb strings.Builder
	sb.WriteString(`<!DOCTYPE html>
<html>
<head>
<title>Overlay Preview</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{color:#eee;font-family:system-ui,sans-serif;padding:20px;background:` + bgCSS + `}
  h1{margin-bottom:12px;font-size:20px;color:#ccc}
  .toolbar{background:rgba(22,33,62,0.95);padding:14px 18px;border-radius:8px;margin-bottom:16px}
  .row{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin-bottom:8px}
  .row:last-child{margin-bottom:0}
  .row label{font-size:12px;color:#aaa;display:flex;align-items:center;gap:4px}
  .row input,.row select{background:#0f3460;color:#fff;border:1px solid #444;padding:3px 6px;border-radius:4px;font-size:12px}
  .row input[type=number]{width:55px}
  .row input[type=text]{width:140px}
  .row input[type=checkbox]{width:auto}
  .sep{width:1px;height:20px;background:#444;margin:0 2px}
  button{background:#e94560;color:#fff;border:none;padding:5px 14px;border-radius:4px;cursor:pointer;font-size:12px}
  button:hover{background:#c73e54}
  .btn-sm{background:#0f3460;padding:3px 8px;font-size:11px}
  .btn-sm:hover{background:#1a4a8a}
  .btn-sm.active{background:#e94560}
  .grid{` + layoutCSS + `}
  .card{background:rgba(22,33,62,0.85);border-radius:8px;padding:10px}
  .card h3{font-size:13px;color:#aaa;margin-bottom:6px}
  .card img{display:block;image-rendering:pixelated}
  .fmt-checks{display:flex;gap:8px;flex-wrap:wrap}
  .fmt-checks label{font-size:11px}
  details{margin-bottom:16px}
  details summary{cursor:pointer;font-size:14px;color:#ccc;padding:8px 0;user-select:none}
  .style-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(130px,1fr));gap:8px 12px}
  .style-grid label{font-size:11px;color:#aaa;display:flex;align-items:center;gap:4px}
  .style-grid input[type=color]{width:28px;height:22px;border:1px solid #444;border-radius:3px;padding:0;cursor:pointer;background:none}
  .style-grid input[type=text]{width:76px;font-size:11px;font-family:monospace}
  .style-grid input[type=number]{width:50px}
  .size-grid{display:flex;gap:16px;flex-wrap:wrap;margin-top:8px}
  .size-grid label{font-size:11px;color:#aaa;display:flex;align-items:center;gap:4px}
  .preset-row{display:flex;gap:6px;margin-bottom:8px}
</style>
</head>
<body>
<h1>Overlay Preview</h1>
<form class="toolbar" method="get" action="/" id="frm">
  <div class="row">
    <label>Title <input type="text" name="title" value="` + htmlEsc(title) + `"></label>
    <div class="sep"></div>
    <label>Rows <input type="number" name="rows" min="3" max="30" value="` + rows + `"></label>
    <label>Scale <input type="number" name="scale" min="0.5" max="4" step="0.1" value="` + scale + `"></label>
    <label>Competitors <input type="number" name="count" min="1" max="20" value="` + count + `"></label>
    <div class="sep"></div>
    <label>Laps <input type="number" name="laps" min="0" max="999" value="` + laps + `"></label>
    <label>To Go <input type="number" name="lapstogo" min="0" max="999" value="` + lapsToGo + `"></label>
    <label>Race Time <input type="text" name="racetime" value="` + htmlEsc(raceTime) + `" style="width:90px"></label>
  </div>
  <div class="row">
    <label>Flag
    <select name="flag">`)
	for _, opt := range []struct{ val, label string }{
		{"", "None"}, {"Red Flag", "Red Flag"}, {"Yellow Flag", "Yellow Flag"},
		{"Green Flag", "Green Flag"}, {"Checkered Flag", "Checkered"},
	} {
		sel := ""
		if flag == opt.val {
			sel = " selected"
		}
		sb.WriteString(fmt.Sprintf(`<option value="%s"%s>%s</option>`, htmlEsc(opt.val), sel, opt.label))
	}
	sb.WriteString(`</select></label>
    <div class="sep"></div>
    <label>Background
    <select name="bg">`)
	for _, opt := range []struct{ val, label string }{
		{"video", "Dark Blue"}, {"black", "Black"}, {"white", "White"},
		{"green", "Chroma Green"}, {"gray", "Gray"}, {"track", "Track"},
	} {
		sel := ""
		if bg == opt.val {
			sel = " selected"
		}
		sb.WriteString(fmt.Sprintf(`<option value="%s"%s>%s</option>`, opt.val, sel, opt.label))
	}
	sb.WriteString(`</select></label>
    <label>Layout
    <select name="layout">`)
	for _, opt := range []struct{ val, label string }{
		{"grid", "Grid"}, {"column", "Column"}, {"compare", "Compare (2-up)"},
	} {
		sel := ""
		if layout == opt.val {
			sel = " selected"
		}
		sb.WriteString(fmt.Sprintf(`<option value="%s"%s>%s</option>`, opt.val, sel, opt.label))
	}
	sb.WriteString(`</select></label>
    <div class="sep"></div>
    <button type="submit">Update</button>
  </div>
  <div class="row">
    <span style="font-size:12px;color:#888">Formats:</span>
    <div class="fmt-checks">`)
	for _, f := range formats {
		chk := ""
		if showSet[f.value] {
			chk = " checked"
		}
		sb.WriteString(fmt.Sprintf(`<label><input type="checkbox" name="fmt" value="%s"%s> %s</label>`,
			f.value, chk, f.label))
	}
	sb.WriteString(`</div>
  </div>
</form>

<details class="toolbar"`)
	if q.Get("header_bg") != "" || q.Get("row_height") != "" || q.Get("opacity") != "" {
		sb.WriteString(` open`)
	}
	sb.WriteString(`>
  <summary>Style Customization</summary>
  <form method="get" action="/" id="frm2">`)
	// Carry forward all non-style params as hidden
	for _, k := range []string{"title", "rows", "scale", "count", "laps", "lapstogo", "racetime", "flag", "bg", "layout"} {
		sb.WriteString(fmt.Sprintf(`<input type="hidden" name="%s" value="%s">`, k, htmlEsc(qd(q, k, ""))))
	}
	for _, f := range showFormats {
		sb.WriteString(fmt.Sprintf(`<input type="hidden" name="fmt" value="%s">`, f))
	}

	// Presets
	sb.WriteString(`
  <div class="preset-row">
    <span style="font-size:11px;color:#888;padding-top:2px">Presets:</span>
    <button type="button" class="btn-sm" onclick="applyPreset('default')">Default Blue</button>
    <button type="button" class="btn-sm" onclick="applyPreset('dark')">Dark</button>
    <button type="button" class="btn-sm" onclick="applyPreset('f1')">F1 Style</button>
    <button type="button" class="btn-sm" onclick="applyPreset('nascar')">NASCAR</button>
    <button type="button" class="btn-sm" onclick="applyPreset('bright')">Bright</button>
  </div>`)

	// Color fields
	sb.WriteString(`<div class="style-grid">`)
	for _, sf := range styleFields {
		val := styleVals[sf.key]
		hexShort := strings.TrimSuffix(strings.TrimPrefix(val, "#"), "FF")
		if len(hexShort) > 6 {
			hexShort = hexShort[:6]
		}
		colorVal := "#" + hexShort
		if len(hexShort) < 6 {
			colorVal = "#" + val[1:7]
		}
		sb.WriteString(fmt.Sprintf(
			`<label>%s <input type="color" value="%s" onchange="syncColor(this,'%s')"><input type="text" name="%s" id="%s" value="%s"></label>`,
			sf.label, colorVal, sf.key, sf.key, sf.key, htmlEsc(val)))
	}
	sb.WriteString(`</div>`)

	// Sizing fields
	sb.WriteString(`<div class="size-grid">`)
	for _, ss := range styleSizing {
		val := styleVals[ss.key]
		sb.WriteString(fmt.Sprintf(
			`<label>%s <input type="number" name="%s" min="%d" max="%d" value="%s"></label>`,
			ss.label, ss.key, ss.min, ss.max, val))
	}
	sb.WriteString(`
    <button type="submit" style="margin-left:8px">Apply Style</button>
  </div>
  </form>
  <div style="margin-top:12px">
    <label style="font-size:12px;color:#aaa">Current Style Config (copy this):</label>
    <div style="display:flex;gap:8px;align-items:start;margin-top:4px">
      <textarea id="style-export" readonly rows="6" style="flex:1;background:#0a0e24;color:#7fdbca;border:1px solid #444;border-radius:4px;padding:8px;font-family:monospace;font-size:11px;resize:vertical">`)

	// Build JSON style config
	sb.WriteString("{\n")
	allFields := []struct{ key, label string }{}
	for _, sf := range styleFields {
		allFields = append(allFields, struct{ key, label string }{sf.key, sf.label})
	}
	for _, ss := range styleSizing {
		allFields = append(allFields, struct{ key, label string }{ss.key, ss.label})
	}
	for i, af := range allFields {
		v := styleVals[af.key]
		comma := ","
		if i == len(allFields)-1 {
			comma = ""
		}
		sb.WriteString(fmt.Sprintf("  \"%s\": \"%s\"%s\n", af.key, htmlEsc(v), comma))
	}
	sb.WriteString("}")

	sb.WriteString(`</textarea>
      <button type="button" onclick="navigator.clipboard.writeText(document.getElementById('style-export').value).then(()=>{this.textContent='Copied!';setTimeout(()=>{this.textContent='Copy'},1500)})" style="white-space:nowrap">Copy</button>
    </div>
  </div>
</details>
`)

	sb.WriteString(`<div class="grid">`)

	baseParams := fmt.Sprintf("rows=%s&scale=%s&title=%s&flag=%s&laps=%s&lapstogo=%s&racetime=%s&count=%s",
		rows, scale, url.QueryEscape(title), url.QueryEscape(flag), laps, lapsToGo, url.QueryEscape(raceTime), count)

	// Append style params
	for _, sf := range styleFields {
		v := styleVals[sf.key]
		if v != "" && v != sf.def {
			baseParams += "&" + sf.key + "=" + url.QueryEscape(v)
		}
	}
	for _, ss := range styleSizing {
		v := styleVals[ss.key]
		if v != "" && v != ss.def {
			baseParams += "&" + ss.key + "=" + v
		}
	}

	for _, f := range formats {
		if !showSet[f.value] {
			continue
		}
		imgURL := fmt.Sprintf("/render?format=%s&%s", f.value, baseParams)
		sb.WriteString(fmt.Sprintf(`
  <div class="card">
    <h3>%s <code>(%s)</code></h3>
    <img src="%s">
  </div>`, f.label, f.value, imgURL))
	}

	sb.WriteString(`
</div>
<script>
// Auto-submit on control changes
document.querySelectorAll('#frm select, #frm input[type=checkbox]').forEach(el => {
  el.addEventListener('change', () => document.getElementById('frm').submit());
});

function syncColor(picker, id) {
  const hex = picker.value.replace('#','').toUpperCase();
  document.getElementById(id).value = '#' + hex + 'FF';
}

const presets = {
  default: {header_bg:'#0F123CF5',accent_color:'#C8AA00FF',row_bg_even:'#121632',row_bg_odd:'#0C0F26',row_separator:'#282D46B4',text_color:'#FFFFFFFF',pos_color:'#FFDC28FF',p1_color:'#FFD700FF',num_color:'#DCDCDCFF',gap_color:'#00D25AFF',best_lap_color:'#FF00FFFF',lap_info_color:'#FFFFFFFF',row_height:'22',header_height:'26',pad_x:'8',opacity:'230'},
  dark: {header_bg:'#111111F0',accent_color:'#FF4444FF',row_bg_even:'#1A1A1A',row_bg_odd:'#141414',row_separator:'#333333B4',text_color:'#EEEEEEFF',pos_color:'#FF6666FF',p1_color:'#FF4444FF',num_color:'#BBBBBBFF',gap_color:'#44CC44FF',best_lap_color:'#FF00FFFF',lap_info_color:'#DDDDDDFF',row_height:'22',header_height:'26',pad_x:'8',opacity:'240'},
  f1: {header_bg:'#E10600F0',accent_color:'#FFFFFFFF',row_bg_even:'#15151E',row_bg_odd:'#1E1E2A',row_separator:'#38383FB4',text_color:'#FFFFFFFF',pos_color:'#FFFFFFFF',p1_color:'#FFD700FF',num_color:'#CCCCCCFF',gap_color:'#00D2BEFF',best_lap_color:'#A855F7FF',lap_info_color:'#FFFFFFFF',row_height:'22',header_height:'28',pad_x:'8',opacity:'235'},
  nascar: {header_bg:'#002D72F0',accent_color:'#FFD700FF',row_bg_even:'#1A2744',row_bg_odd:'#14203A',row_separator:'#3A4A6AB4',text_color:'#FFFFFFFF',pos_color:'#FFD700FF',p1_color:'#FFD700FF',num_color:'#DDDDDDFF',gap_color:'#FF6B35FF',best_lap_color:'#FF00FFFF',lap_info_color:'#FFFFFFFF',row_height:'24',header_height:'28',pad_x:'8',opacity:'230'},
  bright: {header_bg:'#1E3A5FF0',accent_color:'#00CCFFFF',row_bg_even:'#0A1929',row_bg_odd:'#0D2137',row_separator:'#1A3A5AB4',text_color:'#FFFFFFFF',pos_color:'#00CCFFFF',p1_color:'#FFCC00FF',num_color:'#EEEEEEFF',gap_color:'#66FF66FF',best_lap_color:'#FF66CCFF',lap_info_color:'#FFFFFFFF',row_height:'22',header_height:'26',pad_x:'8',opacity:'230'},
};

function applyPreset(name) {
  const p = presets[name];
  if (!p) return;
  for (const [k,v] of Object.entries(p)) {
    const el = document.getElementById(k) || document.querySelector('#frm2 [name="'+k+'"]');
    if (el) el.value = v;
  }
  document.getElementById('frm2').submit();
}
</script>
</body>
</html>`)

	w.Header().Set("Content-Type", "text/html")
	w.Header().Set("Cache-Control", "no-cache")
	w.Write([]byte(sb.String()))
}

func qd(q url.Values, key, def string) string {
	v := q.Get(key)
	if v == "" {
		return def
	}
	return v
}

func htmlEsc(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "\"", "&quot;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	return s
}
