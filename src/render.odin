package viz

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

Color :: struct {
	r, g, b, a: u8,
}

COL_STRUCT    :: Color{110, 75, 175, 255}
COL_PACKAGE   :: Color{55, 58, 68, 255}
COL_WASTE     :: Color{215, 55, 60, 220}
COL_BORDER    :: Color{15, 16, 20, 255}
COL_BG        :: Color{18, 19, 24, 255}
COL_HEADER_BG :: Color{28, 30, 38, 255}
COL_TEXT      :: Color{225, 228, 235, 255}
COL_TEXT_DIM  :: Color{150, 155, 165, 255}
COL_FIELD_A   :: Color{60, 150, 210, 255}
COL_FIELD_B   :: Color{70, 190, 140, 255}
COL_PADDING   :: Color{225, 45, 50, 255}
COL_SPLIT     :: Color{235, 195, 60, 255}
COL_OWN_PKG   :: Color{20, 105, 95, 255}
// The user's own code uses a green/teal family so "mine" reads at a glance.
COL_OWN_STRUCT  :: Color{45, 160, 110, 255}
COL_OWN_FILE    :: Color{25, 125, 112, 255}
COL_MUTED     :: Color{62, 65, 74, 255}

set_color :: proc(r: ^sdl.Renderer, c: Color) {
	sdl.SetRenderDrawColor(r, c.r, c.g, c.b, c.a)
}

fill_rect :: proc(r: ^sdl.Renderer, rect: sdl.FRect, c: Color) {
	rc := rect
	set_color(r, c)
	sdl.RenderFillRect(r, &rc)
}

draw_rect_outline :: proc(r: ^sdl.Renderer, rect: sdl.FRect, c: Color) {
	rc := rect
	set_color(r, c)
	sdl.RenderRect(r, &rc)
}

draw_text :: proc(r: ^sdl.Renderer, x, y: f32, text: string, c: Color) {
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	set_color(r, c)
	sdl.RenderDebugText(r, x, y, cstr)
}

// Pixels per logical unit (2 on Retina). Drawing happens in logical units and
// the renderer scales by this, so the bitmap debug font stays crisp.
pixel_density: f32 = 1

apply_pixel_density :: proc(r: ^sdl.Renderer, window: ^sdl.Window) {
	pixel_density = max(sdl.GetWindowPixelDensity(window), 1)
	sdl.SetRenderScale(r, pixel_density, pixel_density)
}

draw_text_scaled :: proc(r: ^sdl.Renderer, x, y: f32, text: string, scale: f32, c: Color) {
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	set_color(r, c)
	sdl.SetRenderScale(r, pixel_density * scale, pixel_density * scale)
	sdl.RenderDebugText(r, x / scale, y / scale, cstr)
	sdl.SetRenderScale(r, pixel_density, pixel_density)
}

// Blends `c` toward a neutral grey so internals recede behind the user's code.
mute :: proc(c: Color) -> Color {
	mix :: proc(a, b: u8) -> u8 { return u8((u32(a) * 3 + u32(b) * 7) / 10) }
	return Color{mix(c.r, COL_MUTED.r), mix(c.g, COL_MUTED.g), mix(c.b, COL_MUTED.b), c.a}
}

// Dark text on the bright struct tiles, light text on the darker file
// headers and muted internals, keeping labels at readable contrast.
label_color :: proc(n: ^Node) -> Color {
	return n.kind == .Struct && n.own ? COL_BG : COL_TEXT
}

node_color :: proc(n: ^Node) -> Color {
	switch n.kind {
	case .Struct:
		return n.own ? COL_OWN_STRUCT : mute(COL_STRUCT)
	case .File:
		return n.own ? COL_OWN_FILE : COL_PACKAGE
	case .Root:
		return COL_BG
	}
	return COL_BG
}

MAX_TREEMAP_DEPTH :: 5
CHAR_W :: f32(8) // SDL debug font glyph width at scale 1
LINE_H :: f32(16)

// Truncates `text` so it fits in `max_px` of debug-font width.
clip_text :: proc(text: string, max_px: f32) -> string {
	max_chars := int(max_px / CHAR_W)
	if max_chars <= 0 do return ""
	if len(text) <= max_chars do return text
	if max_chars <= 2 do return text[:max_chars]
	return fmt.tprintf("%s..", text[:max_chars - 2])
}

// Draws the header, wrapping the key help and status onto their own lines
// when the window is too narrow to share a line. Returns the height used.
draw_header :: proc(r: ^sdl.Renderer, state: ^App_State, win_w: i32) -> f32 {
	w := f32(win_w)
	pad := f32(10)

	title := "Struct Layouts"
	help := "[A] internals  [R] rebuild  [Click] open  [RMB/Esc] back"
	title_w := f32(len(title)) * CHAR_W * 2
	help_w := f32(len(help)) * CHAR_W
	help_inline := pad + title_w + 3 * pad + help_w + pad <= w

	// Breadcrumb: root (with struct counts) > zoomed file > open struct.
	crumbs := strings.builder_make(context.temp_allocator)
	path := make([dynamic]^Node, context.temp_allocator)
	append(&path, ..state.nav_stack[:])
	if state.active_root != nil do append(&path, state.active_root)
	if state.viewing_struct != nil do append(&path, state.viewing_struct)
	for n, i in path {
		if i > 0 do strings.write_string(&crumbs, "  >  ")
		strings.write_string(&crumbs, n.name)
		if n.kind == .Root && state.struct_root != nil {
			if n == state.own_structs {
				fmt.sbprintf(&crumbs, " (%d of %d)", struct_count(n), struct_count(state.struct_root))
			} else {
				fmt.sbprintf(&crumbs, " (%d)", struct_count(n))
			}
		}
	}
	crumb_text := strings.to_string(crumbs)

	status_w := f32(len(state.status_msg)) * CHAR_W
	status_inline := state.status_msg == "" || pad + f32(len(crumb_text)) * CHAR_W + 3 * pad + status_w + pad <= w

	lines := 1 + (help_inline ? 0 : 1) + (status_inline ? 0 : 1)
	height := 28 + f32(lines) * LINE_H + 4

	rect := sdl.FRect{0, 0, w, height}
	fill_rect(r, rect, COL_HEADER_BG)
	draw_rect_outline(r, rect, COL_BORDER)

	draw_text_scaled(r, pad, 6, clip_text(title, (w - 2 * pad) / 2) , 2.0, COL_TEXT)
	y := f32(28)
	if help_inline {
		draw_text(r, w - help_w - pad, 10, help, COL_TEXT_DIM)
	} else {
		draw_text(r, pad, y, clip_text(help, w - 2 * pad), COL_TEXT_DIM)
		y += LINE_H
	}

	if status_inline {
		crumb_max := w - 2 * pad
		if state.status_msg != "" {
			crumb_max -= status_w + 3 * pad
			draw_text(r, w - status_w - pad, y, state.status_msg, COL_PADDING)
		}
		draw_text(r, pad, y, clip_text(crumb_text, crumb_max), COL_TEXT_DIM)
	} else {
		draw_text(r, pad, y, clip_text(crumb_text, w - 2 * pad), COL_TEXT_DIM)
		y += LINE_H
		draw_text(r, pad, y, clip_text(state.status_msg, w - 2 * pad), COL_PADDING)
	}

	return height
}

draw_treemap :: proc(r: ^sdl.Renderer, nodes: []^Node, area: sdl.FRect, mx, my: f32, hovered: ^^Node) {
	if len(nodes) == 0 || area.w <= 0 || area.h <= 0 do return
	layout_treemap(nodes, area)
	for n in nodes do draw_treemap_node(r, n, 0, mx, my, hovered)
}

// Top level with internals shown: the user's structs and the internals each
// get their own pane at independent scale (the user's are usually a small
// fraction and would be a sliver otherwise). A share bar keeps the real
// proportion visible.
draw_split_overview :: proc(r: ^sdl.Renderer, state: ^App_State, full, own: ^Node, area: sdl.FRect, mx, my: f32) {
	others := make([dynamic]^Node, context.temp_allocator)
	for n in full.children do if !n.own do append(&others, n)

	// Share bar
	own_n, total_n := struct_count(own), struct_count(full)
	bar := sdl.FRect{area.x, area.y, area.w, LINE_H + 4}
	frac := total_n > 0 ? f32(own_n) / f32(total_n) : 0
	fill_rect(r, bar, COL_MUTED)
	fill_rect(r, sdl.FRect{bar.x, bar.y, max(bar.w * frac, 2), bar.h}, COL_OWN_STRUCT)
	share := fmt.tprintf("your structs %d (%.1f%%)  |  internals %d", own_n, frac * 100, len(others))
	draw_text(r, bar.x + 6, bar.y + 6, clip_text(share, bar.w - 12), COL_TEXT)

	body := sdl.FRect{area.x, area.y + bar.h + 4, area.w, area.h - bar.h - 4}
	gap := f32(6)
	own_pane, other_pane: sdl.FRect
	if body.w >= body.h {
		half := (body.w - gap) / 2
		own_pane = {body.x, body.y, half, body.h}
		other_pane = {body.x + half + gap, body.y, half, body.h}
	} else {
		half := (body.h - gap) / 2
		own_pane = {body.x, body.y, body.w, half}
		other_pane = {body.x, body.y + half + gap, body.w, half}
	}

	panes := [2]struct {
		rect:  sdl.FRect,
		title: string,
		col:   Color,
		nodes: []^Node,
	}{
		{own_pane, "YOUR STRUCTS", COL_OWN_PKG, own.children[:]},
		{other_pane, "INTERNALS (core / base / vendor)", COL_PACKAGE, others[:]},
	}
	for p in panes {
		title_bar := sdl.FRect{p.rect.x, p.rect.y, p.rect.w, LINE_H + 2}
		fill_rect(r, title_bar, p.col)
		draw_text(r, p.rect.x + 4, p.rect.y + 5, clip_text(p.title, p.rect.w - 8), COL_TEXT)
		inner := sdl.FRect{p.rect.x, p.rect.y + title_bar.h, p.rect.w, p.rect.h - title_bar.h}
		draw_treemap(r, p.nodes, inner, mx, my, &state.hovered)
	}
}

// Recursively draws a laid-out node tree, updating hovered^ with the deepest
// node under (mx, my) so click handlers can act on the most specific target.
draw_treemap_node :: proc(r: ^sdl.Renderer, n: ^Node, depth: int, mx, my: f32, hovered: ^^Node) {
	rect := n.rect
	if rect.w <= 0 || rect.h <= 0 do return

	inside := mx >= rect.x && mx < rect.x + rect.w && my >= rect.y && my < rect.y + rect.h
	if inside {
		hovered^ = n
	}

	fill_rect(r, rect, node_color(n))

	if n.kind == .Struct && n.size > 0 && n.pad_bytes > 0 {
		waste_frac := f32(n.pad_bytes) / f32(n.size)
		if waste_frac > 1 do waste_frac = 1
		wh := rect.h * waste_frac
		if wh < 2 do wh = 2
		waste_rect := sdl.FRect{rect.x, rect.y + rect.h - wh, rect.w, wh}
		fill_rect(r, waste_rect, COL_WASTE)
	}

	draw_rect_outline(r, rect, COL_BORDER)

	if rect.w > 34 && rect.h > 14 {
		label := clip_text(n.name, rect.w - 6)
		draw_text(r, rect.x + 3, rect.y + 3, label, label_color(n))
	}

	if depth >= MAX_TREEMAP_DEPTH do return
	if len(n.children) == 0 do return
	if rect.w < 24 || rect.h < 18 do return

	inset := sdl.FRect{rect.x + 2, rect.y + 16, rect.w - 4, rect.h - 18}
	if inset.w <= 0 || inset.h <= 0 do return

	layout_treemap(n.children[:], inset)
	for child in n.children {
		draw_treemap_node(r, child, depth + 1, mx, my, hovered)
	}
}

// Color of field `fi` in the detail view: padding red, cache-line splits
// yellow, and real fields alternating so neighbours stay distinguishable.
field_colors :: proc(s: ^Node) -> []Color {
	colors := make([]Color, len(s.fields), context.temp_allocator)
	real := 0
	for f, fi in s.fields {
		switch {
		case f.is_padding:
			colors[fi] = COL_PADDING
		case field_splits_cacheline(f):
			colors[fi] = COL_SPLIT
		case:
			colors[fi] = real % 2 == 0 ? COL_FIELD_A : COL_FIELD_B
		}
		if !f.is_padding do real += 1
	}
	return colors
}

field_splits_cacheline :: proc(f: Struct_Field) -> bool {
	if f.is_padding || f.size == 0 || f.size >= 64 do return false
	return f.offset / 64 != (f.offset + f.size - 1) / 64
}

point_in :: proc(rc: sdl.FRect, x, y: f32) -> bool {
	return x >= rc.x && x < rc.x + rc.w && y >= rc.y && y < rc.y + rc.h
}

DETAIL_CELL_W :: f32(44)
DETAIL_CELL_H :: f32(22)
DETAIL_ROW_H  :: f32(20)
COL_ACCENT    :: Color{95, 205, 175, 255}

// Draws `label` dim then `value` bright (or `value_col`) and returns the x
// after the pair, for a row of stats.
draw_stat :: proc(r: ^sdl.Renderer, x, y: f32, label, value: string, value_col := COL_TEXT) -> f32 {
	draw_text(r, x, y, label, COL_TEXT_DIM)
	vx := x + f32(len(label) + 1) * CHAR_W
	draw_text(r, vx, y, value, value_col)
	return vx + f32(len(value)) * CHAR_W + 4 * CHAR_W
}

// Right-aligns `text` so it ends at `right`.
draw_text_right :: proc(r: ^sdl.Renderer, right, y: f32, text: string, c: Color) {
	draw_text(r, right - f32(len(text)) * CHAR_W, y, text, c)
}

// Clicked-struct view: a title block (name, source, stats), the bytes as an
// 8-wide grid split into 64-byte cache lines, and a field table (offset,
// size, name, type) with padding holes and cache-line boundaries. Hovering a
// field in either the grid or the table highlights it in both.
draw_struct_detail :: proc(r: ^sdl.Renderer, s: ^Node, area: sdl.FRect, mx, my: f32) {
	pad := f32(20)
	x0 := area.x + pad
	y := area.y + 16

	// Title block: name > where it lives > stats.
	draw_text_scaled(r, x0, y, clip_text(s.name, (area.w - 2 * pad) / 2), 2.0, COL_TEXT)
	y += 26
	if s.decl.line > 0 {
		draw_text(r, x0, y, clip_text(fmt.tprintf("%s:%d", s.decl.file, s.decl.line), area.w - 2 * pad), COL_ACCENT)
		y += 20
	}
	waste_pct := s.size > 0 ? f32(s.pad_bytes) / f32(s.size) * 100 : 0
	sx := x0
	sx = draw_stat(r, sx, y, "SIZE", fmt_size(s.size))
	sx = draw_stat(r, sx, y, "FIELDS", fmt.tprintf("%d", len(s.fields) - padding_field_count(s)))
	sx = draw_stat(r, sx, y, "PADDING", fmt.tprintf("%d B (%.1f%%)", s.pad_bytes, waste_pct), s.pad_bytes > 0 ? COL_PADDING : COL_TEXT)
	sx = draw_stat(r, sx, y, "CACHE LINES", fmt.tprintf("%d", s.cachelines))
	y += 22
	fill_rect(r, sdl.FRect{x0, y, area.w - 2 * pad, 1}, COL_HEADER_BG)
	y += 18

	if s.size == 0 do return
	total_bytes := int(s.size)
	colors := field_colors(s)

	field_of_byte := make([]int, total_bytes, context.temp_allocator)
	for &b in field_of_byte do b = -1
	for f, fi in s.fields {
		for b := int(f.offset); b < int(f.offset + f.size) && b < total_bytes; b += 1 do field_of_byte[b] = fi
	}

	// Table columns (fixed width, so it doesn't stretch across wide windows).
	col_swatch := f32(0)
	col_off_end := col_swatch + 18 + 6 * CHAR_W
	col_size_end := col_off_end + 6 * CHAR_W
	col_name := col_size_end + 3 * CHAR_W
	col_type := col_name + 20 * CHAR_W
	table_w := col_type + 28 * CHAR_W

	// Side by side when there's room for the table, otherwise stacked.
	grid_w := DETAIL_CELL_W * 8
	table_x := x0 + grid_w + 48
	table_y := y
	stacked := area.x + area.w - pad - table_x < table_w

	// Pass 1: place grid rows and table rows so hover is known before drawing.
	cells := make([]sdl.FRect, total_bytes, context.temp_allocator)
	Cl_Header :: struct {
		y:  f32,
		cl: int,
	}
	cl_headers := make([dynamic]Cl_Header, context.temp_allocator)
	gy := y
	rows := (total_bytes + 7) / 8
	for row := 0; row < rows; row += 1 {
		if row % 8 == 0 {
			append(&cl_headers, Cl_Header{gy, row / 8})
			gy += 20
		}
		for col := 0; col < 8; col += 1 {
			b := row * 8 + col
			if b < total_bytes do cells[b] = {x0 + f32(col) * DETAIL_CELL_W, gy, DETAIL_CELL_W, DETAIL_CELL_H - 2}
		}
		gy += DETAIL_CELL_H
		if (row + 1) % 8 == 0 do gy += 14
	}
	if stacked {
		table_x = x0
		table_y = gy + 24
	}

	Table_Row :: struct {
		rect:    sdl.FRect,
		field:   int, // -1 for a cache-line divider
		divider: int,
	}
	table_rows := make([dynamic]Table_Row, context.temp_allocator)
	ty := table_y + DETAIL_ROW_H + 4 // below the column headings
	cur_cl := -1
	for f, fi in s.fields {
		if cl := int(f.offset) / 64; cl != cur_cl {
			cur_cl = cl
			append(&table_rows, Table_Row{{table_x, ty, table_w, DETAIL_ROW_H}, -1, cl})
			ty += DETAIL_ROW_H
		}
		append(&table_rows, Table_Row{{table_x, ty, table_w, DETAIL_ROW_H}, fi, 0})
		ty += DETAIL_ROW_H
	}

	hovered := -1
	for rc, b in cells do if point_in(rc, mx, my) do hovered = field_of_byte[b]
	for tr in table_rows do if tr.field >= 0 && point_in(tr.rect, mx, my) do hovered = tr.field

	// Pass 2: grid. Each field is one solid bar per row (so labels aren't cut
	// by cell gaps) with faint ticks at byte boundaries.
	for h in cl_headers {
		label := fmt.tprintf("CACHE LINE %d", h.cl)
		draw_text(r, x0, h.y, label, COL_SPLIT)
		draw_text(r, x0 + f32(len(label) + 2) * CHAR_W, h.y, fmt.tprintf("bytes %d-%d", h.cl * 64, h.cl * 64 + 63), COL_TEXT_DIM)
	}
	for b := 0; b < total_bytes; {
		fi := field_of_byte[b]
		run_end := b + 1
		for run_end < total_bytes && run_end % 8 != 0 && field_of_byte[run_end] == fi do run_end += 1

		first, last := cells[b], cells[run_end - 1]
		run := sdl.FRect{first.x, first.y, last.x + last.w - first.x - 2, first.h}
		fill_rect(r, run, fi >= 0 ? colors[fi] : COL_BG)
		for t := b + 1; t < run_end; t += 1 {
			fill_rect(r, sdl.FRect{cells[t].x - 1, run.y + run.h - 5, 1, 5}, COL_BORDER)
		}

		if fi >= 0 {
			f := s.fields[fi]
			// Label only the row where the field starts.
			if b == int(f.offset) {
				label := f.is_padding ? "pad" : f.name
				draw_text(r, run.x + 4, run.y + 6, clip_text(label, run.w - 8), COL_BG)
			}
			if fi == hovered {
				draw_rect_outline(r, run, COL_TEXT)
				draw_rect_outline(r, sdl.FRect{run.x - 1, run.y - 1, run.w + 2, run.h + 2}, COL_TEXT)
			}
		}
		b = run_end
	}

	// Pass 2: table
	bottom := area.y + area.h
	if table_y < bottom {
		draw_text_right(r, table_x + col_off_end, table_y, "OFFSET", COL_TEXT_DIM)
		draw_text_right(r, table_x + col_size_end, table_y, "SIZE", COL_TEXT_DIM)
		draw_text(r, table_x + col_name, table_y, "FIELD", COL_TEXT_DIM)
		draw_text(r, table_x + col_type, table_y, "TYPE", COL_TEXT_DIM)
		fill_rect(r, sdl.FRect{table_x, table_y + 14, table_w, 1}, COL_HEADER_BG)
	}
	for tr in table_rows {
		rc := tr.rect
		if rc.y + rc.h > bottom do break
		text_y := rc.y + 6
		if tr.field < 0 {
			label := fmt.tprintf("cache line %d", tr.divider)
			draw_text(r, rc.x, text_y, label, COL_SPLIT)
			lx := rc.x + f32(len(label) + 1) * CHAR_W
			fill_rect(r, sdl.FRect{lx, rc.y + rc.h / 2 + 1, rc.x + rc.w - lx, 1}, mute(COL_SPLIT))
			continue
		}
		f := s.fields[tr.field]
		if tr.field == hovered do fill_rect(r, rc, COL_HEADER_BG)
		fill_rect(r, sdl.FRect{rc.x + col_swatch, rc.y + 5, 10, 10}, colors[tr.field])

		num_col := f.is_padding ? COL_PADDING : COL_TEXT_DIM
		draw_text_right(r, rc.x + col_off_end, text_y, fmt.tprintf("%d", f.offset), num_col)
		draw_text_right(r, rc.x + col_size_end, text_y, fmt.tprintf("%d", f.size), num_col)
		if f.is_padding {
			draw_text(r, rc.x + col_name, text_y, "padding", COL_PADDING)
			continue
		}
		draw_text(r, rc.x + col_name, text_y, clip_text(f.name, col_type - col_name - CHAR_W), COL_TEXT)
		splits := field_splits_cacheline(f)
		type_text := splits ? fmt.tprintf("%s  splits cache line", f.type_name) : f.type_name
		draw_text(r, rc.x + col_type, text_y, clip_text(type_text, table_w - col_type), splits ? COL_SPLIT : COL_TEXT_DIM)
	}
}

padding_field_count :: proc(s: ^Node) -> int {
	n := 0
	for f in s.fields do if f.is_padding do n += 1
	return n
}

fmt_size :: proc(bytes: u64) -> string {
	if bytes < 1024 do return fmt.tprintf("%d B", bytes)
	return fmt.tprintf("%.1f KB", f32(bytes) / 1024)
}

// Short summary of what a tile's area measures.
describe_node :: proc(n: ^Node) -> string {
	switch n.kind {
	case .Struct:
		waste_pct := n.size > 0 ? f32(n.pad_bytes) / f32(n.size) * 100 : 0
		return fmt.tprintf("%s, %d B pad (%.0f%%), %d cache line(s)", fmt_size(n.size), n.pad_bytes, waste_pct, n.cachelines)
	case .File:
		return fmt.tprintf("%d structs", len(n.children))
	case .Root:
	}
	return fmt_size(n.size)
}

draw_tooltip :: proc(r: ^sdl.Renderer, n: ^Node, mx, my: f32, win_w, win_h: i32) {
	if n == nil do return

	Line :: struct {
		text:  string,
		color: Color,
	}
	lines := make([dynamic]Line, context.temp_allocator)
	append(&lines, Line{n.name, COL_TEXT})
	append(&lines, Line{describe_node(n), COL_TEXT})
	if n.decl.line > 0 {
		append(&lines, Line{fmt.tprintf("%s:%d", n.decl.file, n.decl.line), COL_TEXT_DIM})
	}

	longest := 0
	for l in lines do longest = max(longest, len(l.text))

	w := f32(longest) * CHAR_W + 16
	h := f32(len(lines)) * LINE_H + 12

	x := mx + 16
	y := my + 16
	if x + w > f32(win_w) do x = f32(win_w) - w - 4
	if y + h > f32(win_h) do y = f32(win_h) - h - 4

	rect := sdl.FRect{x, y, w, h}
	fill_rect(r, rect, COL_HEADER_BG)
	draw_rect_outline(r, rect, COL_TEXT_DIM)

	for l, i in lines {
		draw_text(r, x + 8, y + 6 + f32(i) * LINE_H, l.text, l.color)
	}
}
