package viz

import sdl "vendor:sdl3"

Node_Kind :: enum {
	Root,
	File,
	Struct,
}

// Where a top-level declaration lives in the user's source.
Source_Decl :: struct {
	file: string, // relative to the working directory
	line: int,
}

Struct_Field :: struct {
	name:       string,
	type_name:  string, // as the debug info spells it, e.g. `u16[3]`, `^Node`
	offset:     u32,
	size:       u32,
	is_padding: bool,
}

Node :: struct {
	name:       string,
	size:       u64,
	pad_bytes:  u64,
	cachelines: u32,
	kind:       Node_Kind,
	own:        bool, // declared under the target dir (vs core/base/vendor)
	decl:       Source_Decl,
	rect:       sdl.FRect,
	children:   [dynamic]^Node,
	fields:     [dynamic]Struct_Field,
}

App_State :: struct {
	target_dir:   string,
	bin_path:     string,
	struct_root:  ^Node,
	own_structs:  ^Node, // struct_root narrowed to own_packages, grouped by file
	own_packages: map[string]bool,
	own_decls:    map[string]Source_Decl, // "pkg::Name" -> declaration site
	show_internals: bool,
	active_root:  ^Node,
	nav_stack:    [dynamic]^Node,
	hovered:        ^Node,
	viewing_struct: ^Node,

	status_msg: string,

	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	win_w:    i32,
	win_h:    i32,
}
