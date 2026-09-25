package snapshot

import "core:strings"

// The hard-coded glance model for M0: the sample data from the script block
// in Main.dc.html, parsed from the mockup's own shorthand.

// "a b m +a ~m +c" -> glyphs. `+` = new, `~` = changed.
parse_glyph_shorthand :: proc(s: string, allocator := context.allocator) -> []Glyph_Item {
	out := make([dynamic]Glyph_Item, allocator)
	for tok in strings.fields(s, context.temp_allocator) {
		mark := Mark.Plain
		k := tok
		switch k[0] {
		case '+':
			mark, k = .New, k[1:]
		case '~':
			mark, k = .Changed, k[1:]
		}
		glyph: Glyph
		switch k {
		case "a": glyph = .Op
		case "m": glyph = .Mem
		case "b": glyph = .Branch
		case "c": glyph = .Call
		case: continue
		}
		append(&out, Glyph_Item{glyph, mark})
	}
	return out[:]
}

// "fpn" -> byte cells: f = data, p = padding, n = new data.
parse_cell_shorthand :: proc(s: string, allocator := context.allocator) -> []Byte_Cell {
	out := make([]Byte_Cell, len(s), allocator)
	for ch, i in transmute([]u8)s {
		switch ch {
		case 'p': out[i] = .Padding
		case 'n': out[i] = .New_Data
		case:     out[i] = .Data
		}
	}
	return out
}

sample_glance :: proc(allocator := context.allocator) -> Glance {
	context.allocator = allocator
	pat := []string{"nnn", "gnn", "nnn", "cnn", "ncn", "nnn", "ggn", "nnc", "nng", "nnn", "cnn", "nnn", "gnn", "nnn", "nnn", "ccc"}
	dot :: proc(ch: u8) -> Dot {
		switch ch {
		case 'c': return .Cost
		case 'g': return .Gain
		}
		return .Neutral
	}
	builds := make([]Build_Dots, len(pat))
	for p, i in pat {
		builds[i] = Build_Dots{dot(p[0]), dot(p[1]), dot(p[2]), i == len(pat) - 1}
	}

	quiet := make([]string, 4)
	quiet[0], quiet[1], quiet[2], quiet[3] = "stack", "heap", "opt-out", "vet"

	now := make([]Glyph_Item, 4)
	now[0], now[1], now[2], now[3] = {.Check, .Plain}, {.Check, .Plain}, {.Check, .New}, {.Check, .Plain}
	after := make([]Glyph_Item, 4)
	after[0], after[1], after[2], after[3] = {.Check, .Gain}, {.Check_Removed, .Plain}, {.Check_Removed, .Plain}, {.Check_Removed, .Plain}

	return Glance{
		status = .Ok,
		from = 213,
		to = 214,
		exec = Exec_Lane{
			changed = true,
			symbol = "parse_header",
			delta = 9,
			glyphs = parse_glyph_shorthand("a b m a a b m +a +a +b +m a a b m m m +m ~m +a +c a c a c a c +a +c"),
			inline = Inline_Change{caller = "read_frame", callee = "parse", was_inlined = true, now_inlined = false},
		},
		memory = Memory_Lane{
			changed = true,
			symbol = "Frame_Header",
			delta = 8,
			old_build = 213,
			new_build = 214,
			old_cells = parse_cell_shorthand("fpppffffffffffff"),
			new_cells = parse_cell_shorthand("fpppffffnpppppppffffffff"),
		},
		safety = Safety_Lane{
			changed = true,
			symbol = "parse_header",
			delta = 1,
			now = now,
			after_fix = after,
			asan_done = 9,
			asan_total = 14,
		},
		quiet = quiet,
		builds = builds,
	}
}
