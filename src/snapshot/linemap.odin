package snapshot

import "core:slice"

// SPEC §7.1: an edit moves the lines below it. A Myers diff between the old
// and new text of a file maps each unchanged old line to its new line, so
// positions can be compared across builds.

// Line numbers are 1-based. `old_to_new[i]` is 0 when old line i changed or
// was removed; `new_to_old` is the inverse.
Line_Map :: struct {
	old_to_new: []i32,
	new_to_old: []i32,
}

// Past this edit distance the middle section is treated as all changed;
// the common prefix and suffix are still mapped.
MAX_EDIT_DISTANCE :: 4096

map_lines :: proc(old, new: []string, allocator := context.allocator) -> Line_Map {
	n, m := len(old), len(new)
	lm := Line_Map{
		old_to_new = make([]i32, n + 1, allocator),
		new_to_old = make([]i32, m + 1, allocator),
	}
	pair :: proc(lm: ^Line_Map, o, n: int) {
		lm.old_to_new[o + 1] = i32(n + 1)
		lm.new_to_old[n + 1] = i32(o + 1)
	}

	// Typical saves touch a few lines: match the common prefix and suffix
	// directly, so Myers only sees the changed middle.
	pre := 0
	for pre < n && pre < m && old[pre] == new[pre] {
		pair(&lm, pre, pre)
		pre += 1
	}
	suf := 0
	for suf < n - pre && suf < m - pre && old[n - 1 - suf] == new[m - 1 - suf] {
		pair(&lm, n - 1 - suf, m - 1 - suf)
		suf += 1
	}
	a := old[pre:n - suf]
	b := new[pre:m - suf]
	if len(a) == 0 || len(b) == 0 do return lm

	// Myers' greedy O(ND): v[k] is the furthest x on diagonal k. The state
	// before each step d is kept so the path can be walked back.
	max_d := min(len(a) + len(b), MAX_EDIT_DISTANCE)
	off := max_d + 1
	v := make([]int, 2 * max_d + 3, context.temp_allocator)
	trace := make([dynamic][]int, context.temp_allocator)
	done := false
	for d in 0 ..= max_d {
		append(&trace, slice.clone(v, context.temp_allocator))
		for k := -d; k <= d; k += 2 {
			x := k == -d || (k != d && v[off + k - 1] < v[off + k + 1]) ? v[off + k + 1] : v[off + k - 1] + 1
			y := x - k
			for x < len(a) && y < len(b) && a[x] == b[y] {
				x += 1
				y += 1
			}
			v[off + k] = x
			if x >= len(a) && y >= len(b) {
				done = true
				break
			}
		}
		if done do break
	}
	if !done do return lm

	x, y := len(a), len(b)
	#reverse for vd, d in trace {
		k := x - y
		prev_k := k == -d || (k != d && vd[off + k - 1] < vd[off + k + 1]) ? k + 1 : k - 1
		prev_x := d > 0 ? vd[off + prev_k] : 0
		prev_y := prev_x - prev_k
		for x > prev_x && y > prev_y {
			x -= 1
			y -= 1
			pair(&lm, pre + x, pre + y)
		}
		if d == 0 do break
		x, y = prev_x, prev_y
	}
	return lm
}
