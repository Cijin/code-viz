package snapshot

// The visual vocabulary the views share (SPEC §3.2), independent of SDL.

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





