package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../src/analyze"
import snap "../src/snapshot"

SAMPLE_DWARF_V213 :: #load("samples/dwarf_frame_v213.txt", string)
SAMPLE_DWARF_V214 :: #load("samples/dwarf_frame_v214.txt", string)

@(private)
parse_sample :: proc(text: string) -> map[string]snap.Type_Layout {
	dies := analyze.parse_dies(text, context.temp_allocator)
	idx := analyze.index_dies(dies, context.temp_allocator)
	return analyze.extract_types(dies, idx, "/project", context.temp_allocator)
}

@(private)
expect_fields :: proc(t: ^testing.T, got: snap.Type_Layout, want: []snap.Field, loc := #caller_location) {
	testing.expect_value(t, len(got.fields), len(want), loc = loc)
	for w, i in want {
		if i >= len(got.fields) do break
		f := got.fields[i]
		testing.expect_value(t, f.name, w.name, loc = loc)
		testing.expect_value(t, f.offset, w.offset, loc = loc)
		testing.expect_value(t, f.size, w.size, loc = loc)
	}
}

@(private)
expect_padding :: proc(t: ^testing.T, got: snap.Type_Layout, bytes: int, ranges: []snap.Byte_Range, loc := #caller_location) {
	testing.expect_value(t, snap.padding_bytes(got), bytes, loc = loc)
	r := snap.padding_ranges(got, context.temp_allocator)
	testing.expect_value(t, len(r), len(ranges), loc = loc)
	for w, i in ranges do if i < len(r) do testing.expect_value(t, r[i], w, loc = loc)
}

// fixtures/expected.md, memory table (exact).
@(test)
expected_memory_table_test :: proc(t: ^testing.T) {
	v213 := parse_sample(SAMPLE_DWARF_V213)["frame::Frame_Header"]
	v214 := parse_sample(SAMPLE_DWARF_V214)["frame::Frame_Header"]

	testing.expect_value(t, v213.size, 16)
	testing.expect_value(t, v213.align, 8)
	expect_fields(t, v213, {{name = "kind", offset = 0, size = 1}, {name = "length", offset = 4, size = 4}, {name = "stream_id", offset = 8, size = 8}})
	expect_padding(t, v213, 3, {{1, 3}})

	testing.expect_value(t, v214.size, 24)
	testing.expect_value(t, v214.align, 8)
	expect_fields(t, v214, {{name = "kind", offset = 0, size = 1}, {name = "length", offset = 4, size = 4}, {name = "flags", offset = 8, size = 1}, {name = "stream_id", offset = 16, size = 8}})
	expect_padding(t, v214, 10, {{1, 3}, {9, 15}})

	fix, ok := snap.suggest_reorder(v214, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, fix.size, 16)
	testing.expect_value(t, fix.align, 8)
	expect_fields(t, fix, {{name = "kind", offset = 0, size = 1}, {name = "flags", offset = 1, size = 1}, {name = "length", offset = 4, size = 4}, {name = "stream_id", offset = 8, size = 8}})
	expect_padding(t, fix, 2, {{2, 3}})

	// v213 is already minimal: no suggestion.
	_, ok213 := snap.suggest_reorder(v213, context.temp_allocator)
	testing.expect(t, !ok213)
}

// fixtures/expected.md, cache lines and 10,000 elements.
@(test)
expected_cache_lines_test :: proc(t: ^testing.T) {
	p213 := snap.placement(16, context.temp_allocator)
	testing.expect_value(t, p213.lines, 2)
	testing.expect_value(t, len(p213.spanning), 0)

	p214 := snap.placement(24, context.temp_allocator)
	testing.expect_value(t, p214.lines, 3)
	testing.expect_value(t, len(p214.spanning), 2)
	if len(p214.spanning) == 2 {
		testing.expect_value(t, p214.spanning[0], 2)
		testing.expect_value(t, p214.spanning[1], 5)
	}

	b213, l213 := snap.array_totals(16)
	b214, l214 := snap.array_totals(24)
	testing.expect_value(t, b213, 160_000)
	testing.expect_value(t, l213, 2_500)
	testing.expect_value(t, b214, 240_000)
	testing.expect_value(t, l214, 3_750)
}

@(test)
type_diff_test :: proc(t: ^testing.T) {
	deltas := snap.diff_types(parse_sample(SAMPLE_DWARF_V213), parse_sample(SAMPLE_DWARF_V214), context.temp_allocator)
	testing.expect_value(t, len(deltas), 1)
	d := deltas[0]
	testing.expect_value(t, d.size_delta, 8)
	testing.expect_value(t, d.pad_delta, 7)
	testing.expect_value(t, len(d.new_fields), 1)
	if len(d.new_fields) == 1 do testing.expect_value(t, d.new_fields[0], "flags")
	_, has_fix := d.suggested.?
	testing.expect(t, has_fix)

	new, _ := d.new.?
	cells := snap.byte_cells(new, d.new_fields, context.temp_allocator)
	testing.expect_value(t, len(cells), 24)
	testing.expect_value(t, cells[8], snap.Byte_Cell.New_Data)
	testing.expect_value(t, cells[9], snap.Byte_Cell.Padding)
	testing.expect_value(t, cells[16], snap.Byte_Cell.Data)
}

// The same table from real builds of both fixtures and the installed
// llvm-dwarfdump; also logs the T0 time for the type analyzer (SPEC §9).
@(test)
real_build_memory_test :: proc(t: ^testing.T) {
	if analyze.find_tool("llvm-dwarfdump") == "" {
		fmt.println("skipped: llvm-dwarfdump not found")
		return
	}
	dir := fmt.tprintf("%s/substrate_m2_%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	defer os.remove_all(dir)
	sizes := [2]int{}
	for fixture, i in ([]string{FIXTURE_V213, FIXTURE_V214}) {
		out := fmt.tprintf("%s/%d/app", dir, i)
		os.make_directory_all(fmt.tprintf("%s/%d", dir, i))
		state, _, _, err := os.process_exec({command = {"odin", "build", fixture, "-o:minimal", "-debug", "-build-mode:test", fmt.tprintf("-out:%s", out)}}, context.temp_allocator)
		testing.expect(t, err == nil && state.success)
		abs, _ := os.get_absolute_path(fixture, context.temp_allocator)
		start := time.tick_now()
		types, _, ok := analyze.analyze_dwarf(out, abs, context.temp_allocator)
		fmt.printf("T0 type layout (%s): %.1f ms\n", fixture[len(fixture) - 4:], time.duration_milliseconds(time.tick_since(start)))
		testing.expect(t, ok)
		sizes[i] = types["frame::Frame_Header"].size
	}
	testing.expect_value(t, sizes[0], 16)
	testing.expect_value(t, sizes[1], 24)
}

// The Memory lens "apply" rewrites the declaration in the declared file.
@(test)
reorder_source_test :: proc(t: ^testing.T) {
	src := #load("../fixtures/frame_v214/frame.odin", string)
	out, ok := snap.reorder_struct_source(src, 12, {"kind", "flags", "length", "stream_id"}, context.temp_allocator)
	testing.expect(t, ok)
	lines := strings.split_lines(out, context.temp_allocator)
	testing.expect_value(t, strings.trim_space(lines[12]), "kind:      u8,")
	testing.expect_value(t, strings.trim_space(lines[13]), "flags:     u8,")
	testing.expect_value(t, strings.trim_space(lines[14]), "length:    u32,")
	testing.expect_value(t, strings.trim_space(lines[15]), "stream_id: u64,")
	// Everything outside the struct is unchanged.
	testing.expect_value(t, len(lines), len(strings.split_lines(src, context.temp_allocator)))

	// A stale order (field names that don't match) is refused.
	_, stale := snap.reorder_struct_source(src, 12, {"kind", "flags", "length"}, context.temp_allocator)
	testing.expect(t, !stale)
}

@(test)
glance_memory_lane_test :: proc(t: ^testing.T) {
	prev := snap.Snapshot{id = 213, types = parse_sample(SAMPLE_DWARF_V213)}
	curr := snap.Snapshot{id = 214, types = parse_sample(SAMPLE_DWARF_V214)}
	d := snap.diff(&prev, &curr, context.temp_allocator)
	history := make([dynamic]snap.Build_Dots, context.temp_allocator)
	m := snap.build_glance(&d, &history, context.temp_allocator)
	testing.expect(t, m.memory.changed)
	testing.expect_value(t, m.memory.symbol, "Frame_Header")
	testing.expect_value(t, m.memory.delta, 8)
	testing.expect_value(t, len(m.memory.old_cells), 16)
	testing.expect_value(t, len(m.memory.new_cells), 24)
	testing.expect_value(t, m.memory.new_cells[8], snap.Byte_Cell.New_Data)
	testing.expect_value(t, len(m.builds), 1)
	testing.expect_value(t, m.builds[0].m, snap.Dot.Cost)
}
