package viz

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"

Color :: struct {
	r, g, b, a: u8,
}

COL_CODE      :: Color{40, 110, 180, 255}
COL_DATA_RW   :: Color{210, 95, 45, 255}
COL_DATA_RO   :: Color{75, 140, 95, 255}
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

draw_text_scaled :: proc(r: ^sdl.Renderer, x, y: f32, text: string, scale: f32, c: Color) {
	cstr := strings.clone_to_cstring(text, context.temp_allocator)
	set_color(r, c)
	sdl.SetRenderScale(r, scale, scale)
	sdl.RenderDebugText(r, x / scale, y / scale, cstr)
	sdl.SetRenderScale(r, 1, 1)
}

node_color :: proc(n: ^Node) -> Color {
	switch n.kind {
	case .Code:
		return COL_CODE
	case .Data_RW:
		return COL_DATA_RW
	case .Data_RO:
		return COL_DATA_RO
	case .Struct:
		return COL_STRUCT
	case .Package:
		return COL_PACKAGE
	case .Root:
		return COL_BG
	}
	return COL_BG
}

kind_label :: proc(k: Node_Kind) -> string {
	switch k {
	case .Code:
		return "Code"
	case .Data_RW:
		return "Mutable RAM"
	case .Data_RO:
		return "Read-Only"
	case .Struct:
		return "Struct"
	case .Package:
		return "Package"
	case .Root:
		return "Root"
	}
	return ""
}

HEADER_HEIGHT :: f32(48)
MAX_TREEMAP_DEPTH :: 5

draw_header :: proc(r: ^sdl.Renderer, state: ^App_State, win_w: i32) {
	rect := sdl.FRect{0, 0, f32(win_w), HEADER_HEIGHT}
	fill_rect(r, rect, COL_HEADER_BG)
	draw_rect_outline(r, rect, COL_BORDER)

	title := state.show_structs ? "Structs (DWARF) / Cache-Line View" : "Memory / Binary Footprint Treemap"
	draw_text_scaled(r, 10, 6, title, 2.0, COL_TEXT)

	crumbs := strings.builder_make(context.temp_allocator)
	strings.write_string(&crumbs, "path: ")
	for n, i in state.nav_stack {
		if i > 0 do strings.write_string(&crumbs, " > ")
		strings.write_string(&crumbs, n.name)
	}
	if len(state.nav_stack) > 0 do strings.write_string(&crumbs, " > ")
	if state.active_root != nil do strings.write_string(&crumbs, state.active_root.name)
	if state.viewing_struct != nil {
		strings.write_string(&crumbs, " > ")
		strings.write_string(&crumbs, state.viewing_struct.name)
	}
	draw_text(r, 10, 28, strings.to_string(crumbs), COL_TEXT_DIM)

	help := "[Tab] toggle view  [R] rebuild  [Click] zoom in  [Right-click/Esc/Backspace] zoom out"
	help_w := f32(len(help)) * 8
	draw_text(r, f32(win_w) - help_w - 10, 10, help, COL_TEXT_DIM)

	if state.status_msg != "" {
		draw_text(r, f32(win_w) - f32(len(state.status_msg)) * 8 - 10, 30, state.status_msg, COL_PADDING)
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
		label := n.name
		max_chars := int(rect.w / 8) - 1
		if max_chars > 0 && len(label) > max_chars {
			label = label[:max_chars]
		}
		draw_text(r, rect.x + 3, rect.y + 3, label, COL_TEXT)
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

// Level 3: renders `s`'s bytes as an 8-byte-wide, 8-row-per-cacheline grid,
// coloring struct fields (alternating), padding holes (red), and any field
// that straddles a 64-byte cacheline boundary (yellow).
draw_struct_cache_grid :: proc(r: ^sdl.Renderer, s: ^Node, area: sdl.FRect, mx, my: f32) {
	if s.size == 0 do return

	total_bytes := int(s.size)
	rows := (total_bytes + 7) / 8
	cell_w := (area.w - 20) / 8
	if cell_w > 46 do cell_w = 46
	row_h := f32(22)

	cacheline_gap := f32(22)
	x0 := area.x + 16
	y := area.y + 10

	field_of_byte := make([]int, total_bytes, context.temp_allocator)
	for i := 0; i < total_bytes; i += 1 do field_of_byte[i] = -1
	for fi := 0; fi < len(s.fields); fi += 1 {
		f := s.fields[fi]
		for b := int(f.offset); b < int(f.offset) + int(f.size) && b < total_bytes; b += 1 {
			field_of_byte[b] = fi
		}
	}

	for row := 0; row < rows; row += 1 {
		if row % 8 == 0 {
			cl := row / 8
			hdr := fmt.tprintf("CACHE LINE #%d (Bytes %d..%d)", cl, cl * 64, cl * 64 + 63)
			draw_text(r, x0, y, hdr, COL_TEXT)
			y += 18
			line_rect := sdl.FRect{x0, y - 2, cell_w * 8, 2}
			fill_rect(r, line_rect, COL_SPLIT)
		}

		for col := 0; col < 8; col += 1 {
			b := row * 8 + col
			cell := sdl.FRect{x0 + f32(col) * cell_w, y, cell_w - 2, row_h - 2}

			if b >= total_bytes {
				fill_rect(r, cell, COL_BG)
				draw_rect_outline(r, cell, COL_BORDER)
				continue
			}

			fi := field_of_byte[b]
			col_color := COL_PADDING
			label := "PADDING"
			is_pad := true
			if fi >= 0 {
				f := s.fields[fi]
				is_pad = f.is_padding
				label = f.name
				col_color = f.is_padding ? COL_PADDING : (fi % 2 == 0 ? COL_FIELD_A : COL_FIELD_B)

				field_start_cl := int(f.offset) / 64
				field_end_cl := int(f.offset + f.size - 1) / 64
				if !f.is_padding && f.size < 64 && field_start_cl != field_end_cl {
					col_color = COL_SPLIT
				}
			}

			fill_rect(r, cell, col_color)
			draw_rect_outline(r, cell, COL_BORDER)

			inside := mx >= cell.x && mx < cell.x + cell.w && my >= cell.y && my < cell.y + cell.h
			if inside {
				tip := fmt.tprintf("byte %d: %s%s", b, label, is_pad ? " (hole)" : "")
				draw_text(r, area.x, area.y + area.h - 20, tip, COL_TEXT)
			}
		}

		y += row_h + (((row + 1) % 8 == 0) ? cacheline_gap - row_h : 0)
	}
}

draw_tooltip :: proc(r: ^sdl.Renderer, n: ^Node, mx, my: f32, win_w, win_h: i32) {
	if n == nil do return

	lines := make([dynamic]string, context.temp_allocator)
	append(&lines, n.name)
	append(&lines, fmt.tprintf("Kind: %s", kind_label(n.kind)))
	append(&lines, fmt.tprintf("Size: %d B (%.2f KB)", n.size, f32(n.size) / 1024))

	if n.kind == .Struct {
		waste_pct := n.size > 0 ? f32(n.pad_bytes) / f32(n.size) * 100 : 0
		append(&lines, fmt.tprintf("Padding: %d B (%.1f%% waste)", n.pad_bytes, waste_pct))
		append(&lines, fmt.tprintf("Cachelines spanned: %d", n.cachelines))
	}

	longest := 0
	for l in lines do if len(l) > longest do longest = len(l)

	w := f32(longest) * 8 + 16
	h := f32(len(lines)) * 16 + 12

	x := mx + 16
	y := my + 16
	if x + w > f32(win_w) do x = f32(win_w) - w - 4
	if y + h > f32(win_h) do y = f32(win_h) - h - 4

	rect := sdl.FRect{x, y, w, h}
	fill_rect(r, rect, COL_HEADER_BG)
	draw_rect_outline(r, rect, COL_TEXT_DIM)

	for l, i in lines {
		draw_text(r, x + 8, y + 6 + f32(i) * 16, l, COL_TEXT)
	}
}
