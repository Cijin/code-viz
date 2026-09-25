package viz

import sdl "vendor:sdl3"

Node_Kind :: enum {
	Root,
	Package,
	Code,
	Data_RW,
	Data_RO,
	Struct,
}

Struct_Field :: struct {
	name:       string,
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
	rect:       sdl.FRect,
	children:   [dynamic]^Node,
	fields:     [dynamic]Struct_Field,
}

App_State :: struct {
	target_dir:   string,
	bin_path:     string,
	symbol_root:  ^Node,
	struct_root:  ^Node,
	active_root:  ^Node,
	nav_stack:    [dynamic]^Node,
	show_structs:   bool,
	hovered:        ^Node,
	viewing_struct: ^Node,

	status_msg: string,

	window:   ^sdl.Window,
	renderer: ^sdl.Renderer,
	win_w:    i32,
	win_h:    i32,
}
