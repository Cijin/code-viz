package viz

import sdl "vendor:sdl3"

node_weight :: proc(n: ^Node) -> u64 {
	return max(n.size, 1)
}

sort_nodes_by_size_desc :: proc(nodes: []^Node) {
	for i := 1; i < len(nodes); i += 1 {
		j := i
		for j > 0 && nodes[j - 1].size < nodes[j].size {
			nodes[j - 1], nodes[j] = nodes[j], nodes[j - 1]
			j -= 1
		}
	}
}

Squarify_Item :: struct {
	node: ^Node,
	area: f64,
}

// Worst aspect ratio achievable by laying `row` out along a strip of the
// given fixed `side` length (Bruls/Huizing/van Wijk squarified formula).
worst_ratio :: proc(row: []Squarify_Item, side: f64) -> f64 {
	if len(row) == 0 || side <= 0 do return 1e300

	sum: f64 = 0
	mx: f64 = -1e300
	mn: f64 = 1e300
	for it in row {
		sum += it.area
		if it.area > mx do mx = it.area
		if it.area < mn do mn = it.area
	}
	if sum <= 0 || mn <= 0 do return 1e300

	s2 := sum * sum
	side2 := side * side
	a := (side2 * mx) / s2
	b := s2 / (side2 * mn)
	return max(a, b)
}

// Places `row` as a strip peeled off the box (x, y, dx, dy): when `vertical`
// is true the strip is a column of width `covered/dy` at the left edge with
// items stacked top-to-bottom; otherwise it's a row of height `covered/dx`
// at the top edge with items placed left-to-right. Returns the remaining box.
layout_strip :: proc(row: []Squarify_Item, x, y, dx, dy: f64, vertical: bool) -> (nx, ny, ndx, ndy: f64) {
	covered: f64 = 0
	for it in row do covered += it.area

	if vertical {
		width := dy > 0 ? covered / dy : 0
		cy := y
		for it in row {
			item_h := width > 0 ? it.area / width : 0
			it.node.rect = sdl.FRect{f32(x), f32(cy), f32(width), f32(item_h)}
			cy += item_h
		}
		return x + width, y, dx - width, dy
	}

	height := dx > 0 ? covered / dx : 0
	cx := x
	for it in row {
		item_w := height > 0 ? it.area / height : 0
		it.node.rect = sdl.FRect{f32(cx), f32(y), f32(item_w), f32(height)}
		cx += item_w
	}
	return x, y + height, dx, dy - height
}

squarify_rec :: proc(items: []Squarify_Item, x, y, dx, dy: f64) {
	if len(items) == 0 do return
	if len(items) == 1 {
		items[0].node.rect = sdl.FRect{f32(x), f32(y), f32(dx), f32(dy)}
		return
	}

	side := min(dx, dy)
	i := 1
	for i < len(items) {
		cur_worst := worst_ratio(items[:i], side)
		next_worst := worst_ratio(items[:i + 1], side)
		if next_worst > cur_worst do break
		i += 1
	}

	row := items[:i]
	remaining := items[i:]

	nx, ny, ndx, ndy := layout_strip(row, x, y, dx, dy, dx >= dy)
	squarify_rec(remaining, nx, ny, ndx, ndy)
}

// Squarified treemap: sorts nodes descending by size, then recursively peels
// strips off the remaining box that minimize each row's worst aspect ratio,
// so even small nodes land as roughly-square (rather than sliver) rects.
layout_treemap :: proc(nodes: []^Node, box: sdl.FRect) {
	if len(nodes) == 0 do return

	sort_nodes_by_size_desc(nodes)

	if len(nodes) == 1 {
		nodes[0].rect = box
		return
	}

	total: f64 = 0
	for n in nodes do total += f64(node_weight(n))
	if total <= 0 do return

	area := f64(box.w) * f64(box.h)
	if area <= 0 {
		for n in nodes do n.rect = box
		return
	}
	scale := area / total

	items := make([]Squarify_Item, len(nodes), context.temp_allocator)
	for n, i in nodes {
		items[i] = Squarify_Item{node = n, area = f64(node_weight(n)) * scale}
	}

	squarify_rec(items, f64(box.x), f64(box.y), f64(box.w), f64(box.h))
}
