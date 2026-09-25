package pipeline

import "base:runtime"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import snap "../snapshot"

// SPEC §4: watcher -> builder -> analyzers -> UI. Workers never touch SDL:
// they send on `events` and call `notify`, which the UI sets to push an SDL
// user event.

Event_Kind :: enum u8 {
	Build_Started,
	Build_Failed,  // the view keeps the last green snapshot
	Build_Green,   // snapshot attached
}

Event :: struct {
	kind:   Event_Kind,
	id:     snap.Build_Id,
	output: string,       // compiler output for failed builds (heap-owned)
	delta:  ^Owned_Delta, // for Build_Green; the receiver owns it
}

// A snapshot and the arena that holds everything it points to. Snapshots
// stay on the builder thread; the UI only ever sees deltas.
Owned_Snapshot :: struct {
	using snap: snap.Snapshot,
	arena:      virtual.Arena,
	artifact:   string, // path of the analyzed binary
}

// A self-contained delta (see snapshot/delta.odin) and its arena.
Owned_Delta :: struct {
	using delta: snap.Delta,
	arena:       virtual.Arena,
}

Build_Request :: struct {
	reason: string,
}

Pipeline :: struct {
	project_dir: string, // absolute
	cache_dir:   string, // <cache>/<project key>
	notify:      proc(),
	events:      chan.Chan(Event),
	requests:    chan.Chan(Build_Request),
	quit:        bool, // atomic
	watcher:     ^thread.Thread,
	builder:     ^thread.Thread,
	next_id:     snap.Build_Id,
	green:       [dynamic]snap.Build_Id, // kept build dirs, oldest first
	last_green:  snap.Build_Id,          // atomic; 0 before the first green build
	prev:        ^Owned_Snapshot,        // builder thread only: last green snapshot
}

// Everything that crosses threads (events, snapshots, pipeline state) uses
// the process heap, so any thread can free it.
shared_allocator :: proc() -> runtime.Allocator {
	return runtime.heap_allocator()
}

WATCH_POLL_MS :: 250
DEBOUNCE_MS   :: 300
KEEP_GREEN    :: 2

// Cache root per platform: ~/Library/Caches (macOS), $XDG_CACHE_HOME or
// ~/.cache (Linux).
cache_root :: proc() -> string {
	when ODIN_OS == .Darwin {
		return fmt.aprintf("%s/Library/Caches/substrate", os.get_env("HOME", context.temp_allocator))
	} else {
		if xdg := os.get_env("XDG_CACHE_HOME", context.temp_allocator); xdg != "" {
			return fmt.aprintf("%s/substrate", xdg)
		}
		return fmt.aprintf("%s/.cache/substrate", os.get_env("HOME", context.temp_allocator))
	}
}

// Stable directory name for a project: basename plus an FNV-1a hash of the
// absolute path.
project_key :: proc(abs_dir: string) -> string {
	h: u64 = 14695981039346656037
	for b in transmute([]u8)abs_dir do h = (h ~ u64(b)) * 1099511628211
	base := abs_dir
	if i := strings.last_index_byte(abs_dir, '/'); i >= 0 do base = abs_dir[i + 1:]
	return fmt.aprintf("%s-%016x", base, h)
}

// `cache_dir` overrides the default cache root (tests use a temp dir).
start :: proc(p: ^Pipeline, project_dir: string, notify: proc(), cache_dir := "") -> bool {
	context.allocator = shared_allocator()
	abs, err := os.get_absolute_path(project_dir, context.allocator)
	if err != nil do return false
	p.project_dir = abs
	root := cache_dir != "" ? strings.clone(cache_dir) : cache_root()
	key := project_key(abs)
	p.cache_dir = fmt.aprintf("%s/%s", root, key)
	delete(root)
	delete(key)
	p.notify = notify
	if os.make_directory_all(fmt.tprintf("%s/builds", p.cache_dir)) != nil && !os.exists(p.cache_dir) do return false

	p.next_id = load_next_id(p)
	clean_stale_builds(p)

	p.events, _ = chan.create(chan.Chan(Event), 64, context.allocator)
	p.requests, _ = chan.create(chan.Chan(Build_Request), 16, context.allocator)

	// The first build runs immediately; later ones come from the watcher.
	chan.send(p.requests, Build_Request{reason = "start"})
	p.builder = thread.create_and_start_with_poly_data(p, builder_loop)
	p.watcher = thread.create_and_start_with_poly_data(p, watcher_loop)
	return true
}

stop :: proc(p: ^Pipeline) {
	sync.atomic_store(&p.quit, true)
	chan.close(p.requests)
	if p.watcher != nil {
		thread.join(p.watcher)
		thread.destroy(p.watcher)
	}
	if p.builder != nil {
		thread.join(p.builder)
		thread.destroy(p.builder)
	}
	chan.close(p.events)
	for {
		ev, ok := chan.try_recv(p.events)
		if !ok do break
		event_free(&ev)
	}
	chan.destroy(p.events)
	chan.destroy(p.requests)
	snapshot_free(p.prev)

	context.allocator = shared_allocator()
	delete(p.project_dir)
	delete(p.cache_dir)
	delete(p.green)
	p^ = {}
}

// Non-blocking; the UI drains this on each wake-up.
poll :: proc(p: ^Pipeline) -> (ev: Event, ok: bool) {
	return chan.try_recv(p.events)
}

event_free :: proc(ev: ^Event) {
	delete(ev.output, shared_allocator())
	delta_free(ev.delta)
	ev^ = {}
}

delta_free :: proc(d: ^Owned_Delta) {
	if d == nil do return
	virtual.arena_destroy(&d.arena)
	free(d, shared_allocator())
}

snapshot_free :: proc(s: ^Owned_Snapshot) {
	if s == nil do return
	virtual.arena_destroy(&s.arena)
	free(s, shared_allocator())
}

last_green :: proc(p: ^Pipeline) -> snap.Build_Id {
	return sync.atomic_load(&p.last_green)
}

@(private)
emit :: proc(p: ^Pipeline, ev: Event) {
	chan.send(p.events, ev)
	if p.notify != nil do p.notify()
}
