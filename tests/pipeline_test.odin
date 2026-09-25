package tests

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "../src/pipeline"
import snap "../src/snapshot"

FIXTURE_V213 :: #directory + "../fixtures/frame_v213"
FIXTURE_V214 :: #directory + "../fixtures/frame_v214"

// Copies a fixture package into a fresh temp dir; returns (project, cache).
@(private)
temp_project :: proc(t: ^testing.T, fixture, name: string) -> (project, cache: string) {
	root := fmt.tprintf("%s/substrate_test_%s_%d", os.get_env("TMPDIR", context.temp_allocator), name, time.now()._nsec)
	project = fmt.aprintf("%s/frame", root, allocator = context.temp_allocator)
	cache = fmt.aprintf("%s/cache", root, allocator = context.temp_allocator)
	os.make_directory_all(project)
	data, err := os.read_entire_file(fmt.tprintf("%s/frame.odin", fixture), context.temp_allocator)
	testing.expect(t, err == nil)
	_ = os.write_entire_file(fmt.tprintf("%s/frame.odin", project), data)
	return
}

// Waits for the next pipeline event, up to `timeout`.
@(private)
next_event :: proc(p: ^pipeline.Pipeline, timeout: time.Duration) -> (ev: pipeline.Event, ok: bool) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		if ev, ok = pipeline.poll(p); ok do return
		time.sleep(10 * time.Millisecond)
	}
	return {}, false
}

// Drains events until `kind` arrives; counts the builds started on the way.
@(private)
wait_for :: proc(p: ^pipeline.Pipeline, kind: pipeline.Event_Kind, timeout: time.Duration) -> (id: snap.Build_Id, started: int, ok: bool) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		ev, got := next_event(p, timeout - time.tick_since(start))
		if !got do break
		defer pipeline.event_free(&ev)
		if ev.kind == .Build_Started do started += 1
		if ev.kind == kind do return ev.id, started, true
	}
	return 0, started, false
}

// Like wait_for(.Build_Green), but also reads the first type delta.
@(private)
wait_for_green_delta :: proc(p: ^pipeline.Pipeline, timeout: time.Duration) -> (id: snap.Build_Id, started: int, ok: bool, size_delta: int) {
	start := time.tick_now()
	for time.tick_since(start) < timeout {
		ev, got := next_event(p, timeout - time.tick_since(start))
		if !got do break
		defer pipeline.event_free(&ev)
		if ev.kind == .Build_Started do started += 1
		if ev.kind == .Build_Green {
			if ev.delta != nil && len(ev.delta.types) > 0 do size_delta = ev.delta.types[0].size_delta
			return ev.id, started, true, size_delta
		}
	}
	return 0, started, false, 0
}

@(test)
build_command_test :: proc(t: ^testing.T) {
	cmd := pipeline.build_command(FIXTURE_V213, "/tmp/x/app", context.temp_allocator)
	joined := strings.join(cmd, " ", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "-o:minimal -debug"))
	// The fixture has no main, so it must build in test mode.
	testing.expect(t, strings.contains(joined, "-build-mode:test"))
}

@(test)
signature_changes_on_edit_test :: proc(t: ^testing.T) {
	project, _ := temp_project(t, FIXTURE_V213, "sig")
	before := pipeline.source_signature(project)
	testing.expect_value(t, pipeline.source_signature(project), before)
	path := fmt.tprintf("%s/frame.odin", project)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	_ = os.write_entire_file(path, fmt.tprintf("%s\n// edit\n", string(data)))
	testing.expect(t, pipeline.source_signature(project) != before)
	os.remove_all(project)
}

// SPEC §10 M1: editing a fixture file triggers one build; a failed build
// does not change the view (the last green build stays).
@(test)
edit_triggers_one_build_test :: proc(t: ^testing.T) {
	project, cache := temp_project(t, FIXTURE_V213, "m1")
	defer os.remove_all(project)
	defer os.remove_all(cache)

	p: pipeline.Pipeline
	testing.expect(t, pipeline.start(&p, project, nil, cache))
	defer pipeline.stop(&p)

	first, _, ok := wait_for(&p, .Build_Green, 60 * time.Second)
	testing.expect(t, ok)
	testing.expect_value(t, pipeline.last_green(&p), first)

	// One edit -> exactly one build.
	path := fmt.tprintf("%s/frame.odin", project)
	v214, _ := os.read_entire_file(fmt.tprintf("%s/frame.odin", FIXTURE_V214), context.temp_allocator)
	_ = os.write_entire_file(path, v214)
	second, started, ok2, mem_delta := wait_for_green_delta(&p, 60 * time.Second)
	testing.expect(t, ok2)
	// M2 through the pipeline: the v213 -> v214 edit grows Frame_Header by 8 B.
	testing.expect_value(t, mem_delta, 8)
	testing.expect_value(t, started, 1)
	testing.expect(t, second > first)
	// The only follow-up is the build's T1 vet result; no second build.
	vet_id, _, got_vet := wait_for(&p, .Vet_Ready, 30 * time.Second)
	testing.expect(t, got_vet)
	testing.expect_value(t, vet_id, second)
	_, extra := next_event(&p, 800 * time.Millisecond)
	testing.expect(t, !extra)

	// A broken edit fails and leaves the last green build in place.
	_ = os.write_entire_file(path, "package frame\n\nbroken :: proc( {\n")
	failed, _, ok3 := wait_for(&p, .Build_Failed, 60 * time.Second)
	testing.expect(t, ok3)
	testing.expect(t, failed > second)
	testing.expect_value(t, pipeline.last_green(&p), second)
}
