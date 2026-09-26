package main

import "core:math"
import sdl "vendor:sdl3"
import ttf "vendor:sdl3/ttf"

Rect :: struct {
	x, y, w, h: f32,
}

Gfx :: struct {
	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	scale:    f32,
	engine:   ^ttf.TextEngine,
	fonts:    map[Font_Key]^ttf.Font,
	texts:    map[Text_Key]^ttf.Text,
	hatch:    ^sdl.Texture,
	arcs:     map[int][]sdl.FPoint, // unit quarter-arcs per segment count
	verts:    [dynamic]sdl.Vertex,
	indices:  [dynamic]i32,
	path_a:   [dynamic]sdl.FPoint,
	path_b:   [dynamic]sdl.FPoint,
	clips:    [dynamic]sdl.Rect, // clip stack (physical pixels)
}

// The window being drawn; set before each window's frame.
g: ^Gfx

px :: #force_inline proc(v: f32) -> f32 {
	return v * g.scale
}

rect_contains :: proc(r: Rect, x, y: f32) -> bool {
	return x >= r.x && x < r.x + r.w && y >= r.y && y < r.y + r.h
}

inset :: proc(r: Rect, d: f32) -> Rect {
	return Rect{r.x + d, r.y + d, r.w - 2 * d, r.h - 2 * d}
}

@(private = "file")
fcolor :: proc(c: Color) -> sdl.FColor {
	return sdl.FColor{f32(c.r) / 255, f32(c.g) / 255, f32(c.b) / 255, f32(c.a) / 255}
}

fill_rect :: proc(r: Rect, c: Color) {
	rc := sdl.FRect{px(r.x), px(r.y), px(r.w), px(r.h)}
	sdl.SetRenderDrawColor(g.renderer, c.r, c.g, c.b, c.a)
	sdl.RenderFillRect(g.renderer, &rc)
}

// Unit quarter-circle points (0..90°), cached per segment count.
@(private = "file")
quarter_arc :: proc(segments: int) -> []sdl.FPoint {
	if arc, ok := g.arcs[segments]; ok do return arc
	arc := make([]sdl.FPoint, segments + 1)
	for i in 0 ..= segments {
		a := f32(i) / f32(segments) * math.PI / 2
		arc[i] = {math.cos(a), math.sin(a)}
	}
	g.arcs[segments] = arc
	return arc
}

@(private = "file")
arc_segments :: proc(radius_px: f32) -> int {
	return clamp(int(radius_px * 0.7) + 2, 2, 24)
}

// Outline of a rounded rect in physical pixels, clockwise from the top-right
// corner. `segments` is fixed by the caller so inner and outer paths of a
// stroke have matching point counts.
@(private = "file")
rrect_path :: proc(out: ^[dynamic]sdl.FPoint, x, y, w, h, radius: f32, segments: int) {
	clear(out)
	r := clamp(radius, 0, min(w, h) / 2)
	arc := quarter_arc(segments)
	// Corner centers and the quadrant each arc sweeps.
	corners := [4]struct {
		cx, cy, sx, sy: f32,
		flip:           bool,
	}{
		{x + w - r, y + r, 1, -1, true}, // top-right
		{x + w - r, y + h - r, 1, 1, false}, // bottom-right
		{x + r, y + h - r, -1, 1, true}, // bottom-left
		{x + r, y + r, -1, -1, false}, // top-left
	}
	for c in corners {
		for i in 0 ..< len(arc) {
			p := arc[c.flip ? len(arc) - 1 - i : i]
			append(out, sdl.FPoint{c.cx + c.sx * p.x * r, c.cy + c.sy * p.y * r})
		}
	}
}

@(private = "file")
flush_geometry :: proc() {
	if len(g.indices) > 0 {
		sdl.RenderGeometry(g.renderer, nil, raw_data(g.verts), i32(len(g.verts)), raw_data(g.indices), i32(len(g.indices)))
	}
	clear(&g.verts)
	clear(&g.indices)
}

@(private = "file")
vert :: proc(p: sdl.FPoint, c: sdl.FColor) -> i32 {
	append(&g.verts, sdl.Vertex{position = p, color = c})
	return i32(len(g.verts) - 1)
}

fill_rrect :: proc(r: Rect, radius: f32, c: Color) {
	if radius <= 0 {
		fill_rect(r, c)
		return
	}
	rrect_path(&g.path_a, px(r.x), px(r.y), px(r.w), px(r.h), px(radius), arc_segments(px(radius)))
	col := fcolor(c)
	center := vert({px(r.x + r.w / 2), px(r.y + r.h / 2)}, col)
	first := i32(len(g.verts))
	for p in g.path_a do vert(p, col)
	n := i32(len(g.path_a))
	for i in 0 ..< n {
		append(&g.indices, center, first + i, first + (i + 1) % n)
	}
	flush_geometry()
}

// Inset stroke, like CSS `box-shadow: inset 0 0 0 <width>px`.
stroke_rrect :: proc(r: Rect, radius, width: f32, c: Color) {
	segs := arc_segments(px(radius))
	rrect_path(&g.path_a, px(r.x), px(r.y), px(r.w), px(r.h), px(radius), segs)
	rrect_path(&g.path_b, px(r.x + width), px(r.y + width), px(r.w - 2 * width), px(r.h - 2 * width), px(max(radius - width, 0)), segs)
	col := fcolor(c)
	first := i32(len(g.verts))
	for p in g.path_a do vert(p, col)
	for p in g.path_b do vert(p, col)
	n := i32(len(g.path_a))
	for i in 0 ..< n {
		j := (i + 1) % n
		append(&g.indices, first + i, first + j, first + n + i)
		append(&g.indices, first + j, first + n + j, first + n + i)
	}
	flush_geometry()
}

fill_circle :: proc(cx, cy, diameter: f32, c: Color) {
	fill_rrect({cx - diameter / 2, cy - diameter / 2, diameter, diameter}, diameter / 2, c)
}

stroke_circle :: proc(cx, cy, diameter, width: f32, c: Color) {
	stroke_rrect({cx - diameter / 2, cy - diameter / 2, diameter, diameter}, diameter / 2, width, c)
}

// Ring drawn as dashes around its circumference (CSS `border: dashed`).
dashed_circle :: proc(cx, cy, diameter, width: f32, c: Color) {
	col := fcolor(c)
	ro := px(diameter / 2)
	ri := px(diameter / 2 - width)
	ccx, ccy := px(cx), px(cy)
	dash := max(px(width) * 2, 2)
	circumference := 2 * math.PI * ro
	count := max(int(circumference / (dash * 2)), 4)
	step := 2 * math.PI / f32(count)
	for k in 0 ..< count {
		a0 := f32(k) * step
		a1 := a0 + step / 2
		p0 := vert({ccx + math.cos(a0) * ro, ccy + math.sin(a0) * ro}, col)
		p1 := vert({ccx + math.cos(a1) * ro, ccy + math.sin(a1) * ro}, col)
		p2 := vert({ccx + math.cos(a1) * ri, ccy + math.sin(a1) * ri}, col)
		p3 := vert({ccx + math.cos(a0) * ri, ccy + math.sin(a0) * ri}, col)
		append(&g.indices, p0, p1, p2, p0, p2, p3)
	}
	flush_geometry()
}

// Filled square rotated 45°, with `side` as the unrotated edge length.
fill_diamond :: proc(cx, cy, side: f32, c: Color) {
	col := fcolor(c)
	h := px(side) * math.SQRT_TWO / 2
	x, y := px(cx), px(cy)
	a := vert({x, y - h}, col)
	b := vert({x + h, y}, col)
	d := vert({x, y + h}, col)
	e := vert({x - h, y}, col)
	append(&g.indices, a, b, d, a, d, e)
	flush_geometry()
}

// Thick line segment as a quad (logical coords).
line :: proc(x0, y0, x1, y1, width: f32, c: Color) {
	col := fcolor(c)
	dx, dy := x1 - x0, y1 - y0
	l := math.sqrt(dx * dx + dy * dy)
	if l == 0 do return
	nx, ny := -dy / l * width / 2, dx / l * width / 2
	a := vert({px(x0 + nx), px(y0 + ny)}, col)
	b := vert({px(x1 + nx), px(y1 + ny)}, col)
	d := vert({px(x1 - nx), px(y1 - ny)}, col)
	e := vert({px(x0 - nx), px(y0 - ny)}, col)
	append(&g.indices, a, b, d, a, d, e)
	flush_geometry()
}

// The mockups' arrow: a shaft and a 4 px chevron head (`M0 5hN M.. l4 4-4 4`).
arrow :: proc(x, cy, w: f32, c: Color) {
	line(x, cy, x + w - 1, cy, 1.5, c)
	line(x + w - 5, cy - 4, x + w - 1, cy, 1.5, c)
	line(x + w - 1, cy, x + w - 5, cy + 4, 1.5, c)
}

// Dashed rectangular outline (the "changed" modifier), offset outward.
dashed_rect :: proc(r: Rect, offset, width: f32, c: Color) {
	o := Rect{r.x - offset - width, r.y - offset - width, r.w + 2 * (offset + width), r.h + 2 * (offset + width)}
	dash, gap := f32(2), f32(2)
	edge :: proc(x0, y0, x1, y1, width, dash, gap: f32, c: Color) {
		dx, dy := x1 - x0, y1 - y0
		l := math.sqrt(dx * dx + dy * dy)
		for t := f32(0); t < l; t += dash + gap {
			e := min(t + dash, l)
			line(x0 + dx * t / l, y0 + dy * t / l, x0 + dx * e / l, y0 + dy * e / l, width, c)
		}
	}
	h := width / 2
	edge(o.x, o.y + h, o.x + o.w, o.y + h, width, dash, gap, c)
	edge(o.x, o.y + o.h - h, o.x + o.w, o.y + o.h - h, width, dash, gap, c)
	edge(o.x + h, o.y, o.x + h, o.y + o.h, width, dash, gap, c)
	edge(o.x + o.w - h, o.y, o.x + o.w - h, o.y + o.h, width, dash, gap, c)
}

// SPEC §3.2 padding byte: `cost` hatch at 135° (8×8 tile) plus a 1 px
// `cost` outline.
hatch_rect :: proc(r: Rect, radius: f32) {
	push_clip(r)
	dst := sdl.FRect{px(r.x), px(r.y), px(r.w), px(r.h)}
	sdl.RenderTextureTiled(g.renderer, g.hatch, nil, 1, &dst)
	pop_clip()
	stroke_rrect(r, radius, 1, with_alpha(COST, 0.55))
}

// Builds the 8×8 (logical) hatch tile at the current scale: stripes along
// x + y = const, 2 px wide measured across the stripe.
make_hatch_texture :: proc() {
	if g.hatch != nil do sdl.DestroyTexture(g.hatch)
	size := max(int(math.round(px(8))), 8)
	pixels := make([]u32, size * size, context.temp_allocator)
	stripe := f32(size) / 8 * 2 * math.SQRT_TWO
	c := with_alpha(COST, 0.6)
	packed := u32(c.a) << 24 | u32(c.b) << 16 | u32(c.g) << 8 | u32(c.r)
	for y in 0 ..< size do for x in 0 ..< size {
		if f32((x + y) % size) < stripe do pixels[y * size + x] = packed
	}
	g.hatch = sdl.CreateTexture(g.renderer, .ABGR8888, .STATIC, i32(size), i32(size))
	sdl.UpdateTexture(g.hatch, nil, raw_data(pixels), i32(size * 4))
	sdl.SetTextureBlendMode(g.hatch, {.BLEND})
	sdl.SetTextureScaleMode(g.hatch, .NEAREST)
}

// Restricts drawing to `r` (logical coords), intersected with any clip
// already pushed, until the matching pop_clip.
push_clip :: proc(r: Rect) {
	x0, y0 := i32(px(r.x)), i32(px(r.y))
	x1, y1 := x0 + i32(math.ceil(px(max(r.w, 0)))), y0 + i32(math.ceil(px(max(r.h, 0))))
	if n := len(g.clips); n > 0 {
		top := g.clips[n - 1]
		x0, y0 = max(x0, top.x), max(y0, top.y)
		x1, y1 = min(x1, top.x + top.w), min(y1, top.y + top.h)
	}
	clip := sdl.Rect{x0, y0, max(x1 - x0, 0), max(y1 - y0, 0)}
	append(&g.clips, clip)
	sdl.SetRenderClipRect(g.renderer, &clip)
}

pop_clip :: proc() {
	if len(g.clips) > 0 do pop(&g.clips)
	if n := len(g.clips); n > 0 {
		sdl.SetRenderClipRect(g.renderer, &g.clips[n - 1])
	} else {
		sdl.SetRenderClipRect(g.renderer, nil)
	}
}
