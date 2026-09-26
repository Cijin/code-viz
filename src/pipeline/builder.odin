package pipeline

import "core:fmt"
import "core:mem/virtual"
import "core:time"
import "../analyze"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import snap "../snapshot"

// Receives build requests, runs the compiler, and turns green builds into
// snapshots. Requests that queue up while a build runs collapse into one.
@(private)
builder_loop :: proc(p: ^Pipeline) {
	// The last session's final build becomes the first comparison point.
	if p.baseline != 0 do load_baseline(p)
	for {
		_, ok := chan.recv(p.requests)
		if !ok || sync.atomic_load(&p.quit) do return
		for {
			if _, more := chan.try_recv(p.requests); !more do break
		}
		run_build(p)
		free_all(context.temp_allocator)
	}
}

// A package with `main` builds as an executable. Without one (like the
// fixtures) it builds in test mode, the only mode that emits its code
// (docs/VERIFIED.md §1, §4).
package_has_main :: proc(dir: string) -> bool {
	fh, err := os.open(dir)
	if err != nil do return false
	defer os.close(fh)
	entries, _ := os.read_dir(fh, -1, context.temp_allocator)
	for e in entries {
		if e.type == .Directory || !strings.has_suffix(e.name, ".odin") do continue
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr != nil do continue
		for line in strings.split_lines(string(data), context.temp_allocator) {
			if strings.has_prefix(line, "main ") || strings.has_prefix(line, "main:") do return true
		}
	}
	return false
}

// `-o:minimal -debug`: see docs/VERIFIED.md ("Decision"). Returns the
// command as argv.
build_command :: proc(pkg_dir, out_path: string, allocator := context.allocator) -> []string {
	cmd := make([dynamic]string, allocator)
	append(&cmd, "odin", "build", pkg_dir, "-o:minimal", "-debug", fmt.aprintf("-out:%s", out_path, allocator = allocator))
	if !package_has_main(pkg_dir) do append(&cmd, "-build-mode:test")
	return cmd[:]
}

@(private)
build_dir :: proc(p: ^Pipeline, id: snap.Build_Id) -> string {
	return fmt.tprintf("%s/builds/%d", p.cache_dir, id)
}

@(private)
run_build :: proc(p: ^Pipeline) {
	id := p.next_id
	p.next_id += 1
	save_next_id(p)
	emit(p, Event{kind = .Build_Started, id = id})

	dir := build_dir(p, id)
	os.make_directory_all(dir)
	artifact := fmt.tprintf("%s/app", dir)
	state, stdout, stderr, err := os.process_exec(
		{command = build_command(p.project_dir, artifact, context.temp_allocator), working_dir = p.project_dir},
		context.temp_allocator,
	)

	if err != nil || !state.success || state.exit_code != 0 || !os.exists(artifact) {
		out := strings.concatenate({string(stdout), string(stderr)}, shared_allocator())
		if err != nil && out == "" do out = fmt.aprintf("cannot run odin: %v", err, allocator = shared_allocator())
		remove_dir(dir)
		emit(p, Event{kind = .Build_Failed, id = id, output = out})
		return
	}

	s := new(Owned_Snapshot, shared_allocator())
	if virtual.arena_init_growing(&s.arena) != nil {
		free(s, shared_allocator())
		return
	}
	t0 := time.tick_now()
	{
		context.allocator = virtual.arena_allocator(&s.arena)
		s.id = id
		s.artifact = strings.clone(artifact)
		run_analyzers(p, s, read_sources(p.project_dir))
	}
	save_build_sources(dir, s.source)

	d := new(Owned_Delta, shared_allocator())
	if virtual.arena_init_growing(&d.arena) != nil {
		free(d, shared_allocator())
		snapshot_free(s)
		return
	}
	{
		context.allocator = virtual.arena_allocator(&d.arena)
		d.delta = snap.diff(p.prev != nil ? &p.prev.snap : nil, &s.snap)
	}
	// SPEC §9: log the budget timings; never show them in the UI.
	fmt.eprintf("substrate: build %d analyzed in %.1f ms\n", id, time.duration_milliseconds(time.tick_since(t0)))

	prev_vet := p.prev != nil ? p.prev.vet : nil
	keep_green(p, id)
	save_last_green(p, id)
	sync.atomic_store(&p.last_green, id)
	emit(p, Event{kind = .Build_Green, id = id, delta = d})

	// T1: vet runs after the glance data is out (SPEC §6.7). New findings
	// are those the previous build did not report.
	vet := new(Owned_Vet, shared_allocator())
	if virtual.arena_init_growing(&vet.arena) == nil {
		t1 := time.tick_now()
		{
			context.allocator = virtual.arena_allocator(&s.arena)
			s.vet, _ = analyze.run_vet(p.project_dir)
		}
		{
			context.allocator = virtual.arena_allocator(&vet.arena)
			vet.total = len(s.vet)
			vet.new = snap.new_vet_findings(prev_vet, s.vet)
		}
		fmt.eprintf("substrate: build %d vet in %.1f ms\n", id, time.duration_milliseconds(time.tick_since(t1)))
		emit(p, Event{kind = .Vet_Ready, id = id, vet = vet})
	} else {
		free(vet, shared_allocator())
	}
	snapshot_free(p.prev)
	p.prev = s
}

// Analyzer stage (SPEC §6). Runs with context.allocator set to the
// snapshot's arena.
@(private)
run_analyzers :: proc(p: ^Pipeline, s: ^Owned_Snapshot, source: map[string][]string) {
	s.source = source
	s.procs = make(map[string]snap.Proc_Code)

	dw, dw_ok := analyze.analyze_dwarf(s.artifact, p.project_dir)
	if dw_ok {
		s.types = dw.types
	} else {
		fmt.eprintln("substrate: llvm-dwarfdump failed or not found; memory lane disabled")
	}

	code, code_ok := analyze.analyze_code(s.artifact, p.project_dir, source_packages(s.source))
	if !code_ok {
		fmt.eprintln("substrate: llvm-objdump/llvm-nm failed or not found; execution lane disabled")
		return
	}
	checks := make([dynamic]snap.Check_Site)
	for sym, dp in code {
		pc := dp.code
		if info, ok := dw.procs[sym]; ok {
			pc.pos = info.pos
			pc.return_type = info.return_type
			pc.return_size = info.return_size
		}
		if inl, ok := dw.inlining[sym]; ok do pc.inlined = inl
		s.procs[sym] = pc
		append(&checks, ..dp.checks)
	}

	// SPEC §6.4/§6.5: implied checks and opt-outs from the source.
	ast := analyze.analyze_source(s.source)
	emitted := make(map[string]bool, allocator = context.temp_allocator)
	for sym in s.procs do emitted[sym] = true
	append(&checks, ..analyze.removed_checks(ast.implied, checks[:], emitted))
	s.checks = checks[:]
	s.opt_outs = ast.opt_outs
	s.blocks = ast.blocks
}

// Package names declared by the project's files (`package X`).
source_packages :: proc(source: map[string][]string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for _, lines in source {
		for l in lines {
			t := strings.trim_space(l)
			if !strings.has_prefix(t, "package ") do continue
			name := strings.trim_space(t[len("package "):])
			found := false
			for o in out do if o == name do found = true
			if !found do append(&out, name)
			break
		}
	}
	return out[:]
}

// file (project-relative) -> lines, for the line mapping (§7.1).
read_sources :: proc(project_dir: string) -> map[string][]string {
	out := make(map[string][]string)
	walk :: proc(root, dir: string, out: ^map[string][]string) {
		fh, err := os.open(dir)
		if err != nil do return
		defer os.close(fh)
		entries, _ := os.read_dir(fh, -1, context.temp_allocator)
		for e in entries {
			if strings.has_prefix(e.name, ".") || e.name == "build" do continue
			if e.type == .Directory {
				walk(root, e.fullpath, out)
				continue
			}
			if !strings.has_suffix(e.name, ".odin") do continue
			data, rerr := os.read_entire_file(e.fullpath, context.allocator)
			if rerr != nil do continue
			rel := strings.clone(strings.trim_prefix(strings.trim_prefix(e.fullpath, root), "/"))
			out[rel] = strings.split_lines(string(data))
		}
	}
	walk(project_dir, project_dir, &out)
	return out
}

// Keeps the last KEEP_GREEN green build dirs and deletes the rest.
@(private)
keep_green :: proc(p: ^Pipeline, id: snap.Build_Id) {
	if p.green.allocator.procedure == nil do p.green.allocator = shared_allocator()
	append(&p.green, id)
	for len(p.green) > KEEP_GREEN {
		remove_dir(build_dir(p, p.green[0]))
		ordered_remove(&p.green, 0)
	}
}

// Build dirs left from a previous session are removed, except the last
// green one, which is kept as the new session's baseline.
@(private)
clean_stale_builds :: proc(p: ^Pipeline) {
	root := fmt.tprintf("%s/builds", p.cache_dir)
	fh, err := os.open(root)
	if err != nil do return
	defer os.close(fh)
	entries, _ := os.read_dir(fh, -1, context.temp_allocator)
	keep := p.baseline != 0 ? fmt.tprintf("%d", p.baseline) : ""
	for e in entries do if e.type == .Directory && e.name != keep do remove_dir(e.fullpath)
}

// Each green build keeps the source it was built from (<dir>/src), so a
// later session can analyze it again as its baseline.
@(private)
save_build_sources :: proc(dir: string, source: map[string][]string) {
	for rel, lines in source {
		path := fmt.tprintf("%s/src/%s", dir, rel)
		if slash := strings.last_index_byte(path, '/'); slash > 0 do os.make_directory_all(path[:slash])
		_ = os.write_entire_file(path, strings.join(lines, "\n", context.temp_allocator))
	}
}

@(private)
save_last_green :: proc(p: ^Pipeline, id: snap.Build_Id) {
	_ = os.write_entire_file(fmt.tprintf("%s/last_green", p.cache_dir), fmt.tprintf("%d\n", id))
}

// The previous session's last green build, if its artifact and source copy
// are still on disk.
@(private)
load_baseline_id :: proc(p: ^Pipeline) -> snap.Build_Id {
	data, err := os.read_entire_file(fmt.tprintf("%s/last_green", p.cache_dir), context.temp_allocator)
	if err != nil do return 0
	v, ok := strconv.parse_u64(strings.trim_space(string(data)))
	if !ok || v == 0 do return 0
	dir := build_dir(p, snap.Build_Id(v))
	if !os.exists(fmt.tprintf("%s/app", dir)) || !os.exists(fmt.tprintf("%s/src", dir)) do return 0
	return snap.Build_Id(v)
}

// Analyzes the baseline build against its saved source, as `p.prev`.
@(private)
load_baseline :: proc(p: ^Pipeline) {
	s := new(Owned_Snapshot, shared_allocator())
	if virtual.arena_init_growing(&s.arena) != nil {
		free(s, shared_allocator())
		return
	}
	dir := build_dir(p, p.baseline)
	{
		context.allocator = virtual.arena_allocator(&s.arena)
		s.id = p.baseline
		s.artifact = fmt.aprintf("%s/app", dir)
		run_analyzers(p, s, read_sources(fmt.tprintf("%s/src", dir)))
	}
	free_all(context.temp_allocator)
	p.prev = s
	keep_green(p, p.baseline)
}

@(private)
remove_dir :: proc(path: string) {
	os.remove_all(path)
}

// Build ids continue across sessions, like the mockups' 213 -> 214.
@(private)
load_next_id :: proc(p: ^Pipeline) -> snap.Build_Id {
	data, err := os.read_entire_file(fmt.tprintf("%s/next_id", p.cache_dir), context.temp_allocator)
	if err != nil do return 1
	v, ok := strconv.parse_u64(strings.trim_space(string(data)))
	return ok && v > 0 ? snap.Build_Id(v) : 1
}

@(private)
save_next_id :: proc(p: ^Pipeline) {
	_ = os.write_entire_file(fmt.tprintf("%s/next_id", p.cache_dir), fmt.tprintf("%d\n", p.next_id))
}
