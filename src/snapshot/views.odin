package snapshot

// View models: what the UI draws, independent of SDL. The glance view,
// Blocks and the lenses all speak this vocabulary (SPEC §2, §3.2).

Glyph :: enum u8 {
	Op,
	Mem,
	Branch,
	Call,
	Check,
	Check_Removed,
}

// SPEC §3.2 modifiers.
Mark :: enum u8 {
	Plain,
	New,     // cost
	Changed, // dashed outline
	Gain,    // suggested fix
}

Glyph_Item :: struct {
	glyph: Glyph,
	mark:  Mark,
}

Byte_Cell :: enum u8 {
	Data,
	Padding,
	New_Data, // a field byte added by this build
}

Dot :: enum u8 {
	Neutral,
	Cost,
	Gain,
}

Build_Dots :: struct {
	e, m, s: Dot,
	current: bool,
}

Build_Status :: enum u8 {
	Ok,       // last build was green
	Building,
	Failed,   // last build failed; the view keeps the last green snapshot
}

// An inlining change in the execution lane: `callee` was (or was not)
// inlined into `caller` before and after the build.
Inline_Change :: struct {
	caller, callee:        string,
	was_inlined, now_inlined: bool,
}

Exec_Lane :: struct {
	changed: bool,
	symbol:  string,
	delta:   int, // instruction count
	glyphs:  []Glyph_Item,
	inline:  Maybe(Inline_Change),
}

Memory_Lane :: struct {
	changed:    bool,
	symbol:     string,
	delta:      int, // bytes
	old_build:  Build_Id,
	new_build:  Build_Id,
	old_cells:  []Byte_Cell,
	new_cells:  []Byte_Cell,
}

Safety_Lane :: struct {
	changed:     bool,
	symbol:      string,
	delta:       int, // check sites
	now:         []Glyph_Item,
	after_fix:   []Glyph_Item,
	asan_done:   int,
	asan_total:  int, // 0 when no sanitizer run
}

Glance :: struct {
	status:    Build_Status,
	from, to:  Build_Id,
	exec:      Exec_Lane,
	memory:    Memory_Lane,
	safety:    Safety_Lane,
	quiet:     []string, // signals with no change: stack, heap, opt-out, vet
	builds:    []Build_Dots, // last 16 green builds, oldest first
}
