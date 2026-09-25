package main

import "core:fmt"
import "core:strings"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

// SPEC §3.3: IBM Plex Sans Condensed for labels, IBM Plex Mono for code,
// numbers and glyph labels.
Face :: enum u8 {
	Sans_Regular,
	Sans_Medium,
	Sans_SemiBold,
	Sans_Bold,
	Mono_Regular,
	Mono_Medium,
	Mono_SemiBold,
}

FACE_FILES := [Face]string {
	.Sans_Regular  = "IBMPlexSansCondensed-Regular.ttf",
	.Sans_Medium   = "IBMPlexSansCondensed-Medium.ttf",
	.Sans_SemiBold = "IBMPlexSansCondensed-SemiBold.ttf",
	.Sans_Bold     = "IBMPlexSansCondensed-Bold.ttf",
	.Mono_Regular  = "IBMPlexMono-Regular.ttf",
	.Mono_Medium   = "IBMPlexMono-Medium.ttf",
	.Mono_SemiBold = "IBMPlexMono-SemiBold.ttf",
}

Font_Key :: struct {
	face: Face,
	size: f32, // logical px
}

Text_Key :: struct {
	font: Font_Key,
	s:    string,
}

font_dir: string

// Fonts live in assets/fonts next to the repo root; the binary is in build/.
find_font_dir :: proc() -> string {
	base := string(sdl.GetBasePath())
	for candidate in ([]string{fmt.tprintf("%s../assets/fonts", base), fmt.tprintf("%sassets/fonts", base), "assets/fonts"}) {
		probe := strings.clone_to_cstring(fmt.tprintf("%s/%s", candidate, FACE_FILES[.Mono_Regular]), context.temp_allocator)
		if io := sdl.IOFromFile(probe, "rb"); io != nil {
			sdl.CloseIO(io)
			return strings.clone(candidate)
		}
	}
	return "assets/fonts"
}

get_font :: proc(key: Font_Key) -> ^ttf.Font {
	if f, ok := g.fonts[key]; ok do return f
	path := strings.clone_to_cstring(fmt.tprintf("%s/%s", font_dir, FACE_FILES[key.face]), context.temp_allocator)
	f := ttf.OpenFont(path, px(key.size))
	if f == nil {
		fmt.eprintln("substrate: cannot open font", path, sdl.GetError())
		return nil
	}
	g.fonts[key] = f
	return f
}

get_text :: proc(face: Face, size: f32, s: string) -> ^ttf.Text {
	key := Text_Key{Font_Key{face, size}, s}
	if t, ok := g.texts[key]; ok do return t
	f := get_font(key.font)
	if f == nil do return nil
	cs := strings.clone_to_cstring(s, context.temp_allocator)
	t := ttf.CreateText(g.engine, f, cs, 0)
	if t == nil do return nil
	key.s = strings.clone(s)
	g.texts[key] = t
	return t
}

// Drops every cached font and text; used when the display scale changes.
reset_text_cache :: proc() {
	for k, t in g.texts {
		ttf.DestroyText(t)
		delete(k.s)
	}
	clear(&g.texts)
	for _, f in g.fonts do ttf.CloseFont(f)
	clear(&g.fonts)
}

text_size :: proc(face: Face, size: f32, s: string) -> (w, h: f32) {
	if s == "" do return 0, size
	t := get_text(face, size, s)
	if t == nil do return 0, size
	iw, ih: i32
	ttf.GetTextSize(t, &iw, &ih)
	return f32(iw) / g.scale, f32(ih) / g.scale
}

// Draws `s` with its line box vertically centered on `cy`. Returns the width.
draw_text :: proc(face: Face, size: f32, s: string, x, cy: f32, c: Color) -> f32 {
	if s == "" do return 0
	t := get_text(face, size, s)
	if t == nil do return 0
	w, h := text_size(face, size, s)
	ttf.SetTextColor(t, c.r, c.g, c.b, c.a)
	ttf.DrawRendererText(t, px(x), px(cy - h / 2))
	return w
}

draw_text_right :: proc(face: Face, size: f32, s: string, right, cy: f32, c: Color) -> f32 {
	w, _ := text_size(face, size, s)
	draw_text(face, size, s, right - w, cy, c)
	return w
}

// Letter-spaced text (CSS `letter-spacing`), drawn per character.
tracked_width :: proc(face: Face, size, tracking: f32, s: string) -> f32 {
	w: f32
	for i in 0 ..< len(s) {
		cw, _ := text_size(face, size, s[i:i + 1])
		w += cw + tracking * size
	}
	return max(w - tracking * size, 0)
}

draw_tracked :: proc(face: Face, size, tracking: f32, s: string, x, cy: f32, c: Color) -> f32 {
	cx := x
	for i in 0 ..< len(s) {
		cw := draw_text(face, size, s[i:i + 1], cx, cy, c)
		cx += cw + tracking * size
	}
	return max(cx - x - tracking * size, 0)
}

// The `.cap` label style: 12 px, uppercase, 0.12 em tracking, SemiBold.
draw_caps :: proc(s: string, x, cy: f32, c := TEXT_3) -> f32 {
	return draw_tracked(.Sans_SemiBold, CAPS_SIZE, CAPS_TRACKING, strings.to_upper(s, context.temp_allocator), x, cy, c)
}
