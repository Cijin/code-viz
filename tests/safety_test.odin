package tests

import "core:slice"
import "core:strings"
import "core:testing"
import "../src/analyze"
import snap "../src/snapshot"

SAMPLE_VET :: #load("samples/vet_sample.txt", string)

OPT_OUT_SOURCE :: `package demo

fast :: proc(buf: []u8) -> u8 #no_bounds_check {
	return buf[3]
}

peek :: proc(p: rawptr, m: [^]u8) -> int {
	x := transmute(u32)f32(1)
	q := cast(^int)p
	#no_bounds_check {
		_ = m[4]
	}
	return q^ + int(x)
}
`

@(test)
opt_outs_test :: proc(t: ^testing.T) {
	implied := make([dynamic]analyze.Implied_Check, context.temp_allocator)
	outs := make([dynamic]snap.Opt_Out, context.temp_allocator)
	testing.expect(t, analyze.parse_source_file("demo.odin", OPT_OUT_SOURCE, &implied, &outs))

	kinds := make(map[snap.Opt_Out_Kind][dynamic]i32, allocator = context.temp_allocator)
	for o in outs {
		list := kinds[o.kind]
		if list.allocator.procedure == nil do list.allocator = context.temp_allocator
		append(&list, o.pos.line)
		kinds[o.kind] = list
	}
	testing.expect(t, slice.equal(kinds[.No_Bounds_Check][:], []i32{3, 10}))
	testing.expect(t, slice.equal(kinds[.Transmute][:], []i32{8}))
	testing.expect(t, slice.equal(kinds[.Raw_Ptr_Cast][:], []i32{9}))
	testing.expect(t, slice.equal(kinds[.Multi_Pointer][:], []i32{7}))
	// Index expressions inside #no_bounds_check are opt-outs, not checks.
	testing.expect_value(t, len(implied), 0)
}

@(test)
implied_checks_test :: proc(t: ^testing.T) {
	implied := make([dynamic]analyze.Implied_Check, context.temp_allocator)
	outs := make([dynamic]snap.Opt_Out, context.temp_allocator)
	analyze.parse_source_file("frame.odin", SOURCE_V214, &implied, &outs)
	lines := make([dynamic]i32, context.temp_allocator)
	for c in implied do if c.proc_ == "frame::parse_header" do append(&lines, c.pos.line)
	// kind, the length slice, flags, the stream_id slice.
	testing.expect(t, slice.equal(lines[:], []i32{25, 26, 27, 28}))
	testing.expect_value(t, len(outs), 0)
}

@(test)
vet_parse_test :: proc(t: ^testing.T) {
	// The sample: unused imports `fmt` and `os`, and the unused local `x`.
	findings := analyze.parse_vet(SAMPLE_VET, "/project", context.temp_allocator)
	testing.expect_value(t, len(findings), 3)
	if len(findings) == 3 {
		testing.expect_value(t, findings[0].pos.file, "a.odin")
		testing.expect_value(t, findings[0].pos.line, 2)
		testing.expect_value(t, findings[0].message, "'fmt' declared but not used")
	}
	prev := findings[:1]
	testing.expect_value(t, len(snap.new_vet_findings(prev, findings, context.temp_allocator)), 2)
}

// A snapshot with code, checks (actual + removed) and opt-outs, the way the
// pipeline builds it.
@(private)
safety_snapshot :: proc(id: snap.Build_Id, objdump, source: string) -> snap.Snapshot {
	s := snap.Snapshot{id = id}
	s.procs = make(map[string]snap.Proc_Code, allocator = context.temp_allocator)
	s.source = make(map[string][]string, allocator = context.temp_allocator)
	s.source["frame.odin"] = strings.split_lines(source, context.temp_allocator)
	checks := make([dynamic]snap.Check_Site, context.temp_allocator)
	for sym, dp in analyze.parse_objdump(objdump, "/project", .Arm64, context.temp_allocator) {
		pc := dp.code
		pc.pos = {file = "frame.odin", line = dp.code.insns[0].pos.line}
		s.procs[sym] = pc
		append(&checks, ..dp.checks)
	}
	ast := analyze.analyze_source(s.source, context.temp_allocator)
	emitted := make(map[string]bool, allocator = context.temp_allocator)
	for sym in s.procs do emitted[sym] = true
	append(&checks, ..analyze.removed_checks(ast.implied, checks[:], emitted, context.temp_allocator))
	s.checks = checks[:]
	s.opt_outs = ast.opt_outs
	return s
}

// SPEC §10 M4 and fixtures/expected.md (safety): parse_header has one more
// check site in v214, on the `flags` line; opt-outs stay 0 -> 0.
@(test)
one_more_check_on_flags_test :: proc(t: ^testing.T) {
	prev := safety_snapshot(213, SAMPLE_OBJDUMP_V213, SOURCE_V213)
	curr := safety_snapshot(214, SAMPLE_OBJDUMP_V214, SOURCE_V214)
	sd := snap.diff_safety(&prev, &curr, context.temp_allocator)

	ph: snap.Proc_Safety
	for p in sd.procs do if p.symbol == "frame::parse_header" do ph = p
	testing.expect_value(t, ph.old_active, 3)
	testing.expect_value(t, ph.new_active, 4)
	testing.expect(t, ph.changed)

	new_lines := make([dynamic]i32, context.temp_allocator)
	for l in ph.lines do for r in l.checks do if r.mark == .New do append(&new_lines, l.line)
	testing.expect(t, slice.equal(new_lines[:], []i32{27})) // flags := buf[offset+5]

	testing.expect_value(t, sd.opt_outs_old, 0)
	testing.expect_value(t, sd.opt_outs_new, 0)
	testing.expect_value(t, sd.procs[0].symbol, "frame::parse_header")
}
