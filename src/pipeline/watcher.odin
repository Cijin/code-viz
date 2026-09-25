package pipeline

import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:time"

// Mixes every watched file's path, size and mtime. A few stat calls per
// poll; no OS file-watching API needed.
source_signature :: proc(dir: string) -> u64 {
	sig: u64 = 1469598103934665603
	walk_sources(dir, &sig)
	return sig
}

@(private = "file")
walk_sources :: proc(dir: string, sig: ^u64) {
	fh, err := os.open(dir)
	if err != nil do return
	defer os.close(fh)
	entries, rerr := os.read_dir(fh, -1, context.temp_allocator)
	if rerr != nil do return
	for e in entries {
		if strings.has_prefix(e.name, ".") || e.name == "build" do continue
		if e.type == .Directory {
			walk_sources(e.fullpath, sig)
			continue
		}
		if !strings.has_suffix(e.name, ".odin") do continue
		mix :: proc(sig: ^u64, v: u64) {sig^ = (sig^ ~ v) * 1099511628211}
		for b in transmute([]u8)e.fullpath do mix(sig, u64(b))
		mix(sig, u64(e.size))
		mix(sig, u64(time.time_to_unix_nano(e.modification_time)))
	}
}

// Polls every 250 ms. A change is sent once the tree has been quiet for the
// debounce window, so an editor's multi-write save triggers one build.
@(private)
watcher_loop :: proc(p: ^Pipeline) {
	last := source_signature(p.project_dir)
	pending := false
	changed_at: time.Tick
	for !sync.atomic_load(&p.quit) {
		// While a change is pending, wake exactly when the debounce window
		// ends instead of waiting for the next regular poll.
		wait := WATCH_POLL_MS * time.Millisecond
		if pending do wait = max(DEBOUNCE_MS * time.Millisecond - time.tick_since(changed_at), 5 * time.Millisecond)
		time.sleep(wait)
		sig := source_signature(p.project_dir)
		free_all(context.temp_allocator)
		if sig != last {
			last = sig
			pending = true
			changed_at = time.tick_now()
			continue
		}
		if pending && time.tick_since(changed_at) >= DEBOUNCE_MS * time.Millisecond {
			pending = false
			chan.send(p.requests, Build_Request{reason = "change"})
		}
	}
}
