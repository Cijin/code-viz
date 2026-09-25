package snapshot

// SPEC §5 data model. One Snapshot per green build; a Delta (diff.odin)
// compares two of them.

Build_Id :: distinct u32

Source_Pos :: struct {
	file: string, // path relative to the project root
	line: i32,
}

Insn_Kind :: enum u8 {
	Op,
	Mem,
	Branch,
	Call,
}

Insn :: struct {
	kind: Insn_Kind,
	pos:  Source_Pos,
	text: string, // mnemonic and operands, for the "show asm" toggle
	cold: bool,   // in a block that ends in a panic or trap call
}

Proc_Code :: struct {
	symbol:  string,
	size:    int, // bytes of machine code
	insns:   []Insn,
	inlined: []string, // callee names inlined into this proc (from DWARF)
}

Field :: struct {
	name:      string,
	type_name: string,
	offset:    int,
	size:      int,
	align:     int,
}

Type_Layout :: struct {
	name:   string,
	pos:    Source_Pos,
	size:   int,
	align:  int,
	fields: []Field, // sorted by offset
}

Check_Kind :: enum u8 {
	Index,
	Slice,
	Dynamic_Array,
	Type_Assert,
	Matrix,
	Trap,
}

Check_Site :: struct {
	kind:    Check_Kind,
	pos:     Source_Pos,
	proc_:   string,
	removed: bool, // the source has a check here, but the optimized code does not
}

Opt_Out_Kind :: enum u8 {
	No_Bounds_Check,
	Transmute,
	Multi_Pointer,
	Raw_Ptr_Cast,
	Go_Unsafe,
}

Opt_Out :: struct {
	kind: Opt_Out_Kind,
	pos:  Source_Pos,
}

Scenario_Result :: struct {
	test_name:     string,
	insns_exec:    u64,
	l1d_misses:    u64,
	branch_misses: u64,
	calls:         map[string]u64,
	peak_heap:     u64,
	allocs:        u64,
	sanitizer_ok:  Maybe(bool), // nil while running
}

Snapshot :: struct {
	id:       Build_Id,
	time:     i64,
	procs:    map[string]Proc_Code,
	types:    map[string]Type_Layout,
	checks:   []Check_Site,
	opt_outs: []Opt_Out,
	scenario: Maybe(Scenario_Result),
	source:   map[string][]string, // file -> lines, for the line mapping (§7.1)
}
