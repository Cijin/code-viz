package analyze

import "core:strconv"
import "core:strings"
import snap "../snapshot"

// SPEC §6.7: `odin check <pkg> -vet` diagnostics, T1. Lines look like
// `/abs/path.odin(2:8) Error: 'fmt' declared but not used`.

parse_vet :: proc(text, root: string, allocator := context.allocator) -> []snap.Vet_Finding {
	out := make([dynamic]snap.Vet_Finding, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		open := strings.index_byte(line, '(')
		close := strings.index(line, ") ")
		if open <= 0 || close <= open do continue
		loc := line[open + 1:close]
		colon := strings.index_byte(loc, ':')
		if colon <= 0 do continue
		ln, ok := strconv.parse_int(loc[:colon])
		if !ok do continue
		msg := strings.trim_space(line[close + 2:])
		for prefix in ([]string{"Error: ", "Warning: "}) do msg = strings.trim_prefix(msg, prefix)
		rel := project_relative(line[:open], root)
		if rel == "" do continue
		append(&out, snap.Vet_Finding{
			pos     = {file = strings.clone(rel, allocator), line = i32(ln)},
			message = strings.clone(msg, allocator),
		})
	}
	return out[:]
}

run_vet :: proc(pkg_dir: string, allocator := context.allocator) -> (findings: []snap.Vet_Finding, ok: bool) {
	// Vet output goes to stdout+stderr and a vet failure exits non-zero, so
	// read both regardless of the exit code.
	_, stdout, stderr, failed := os_process_exec({"odin", "check", pkg_dir, "-vet", "-no-entry-point"})
	if failed do return nil, false
	text := strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator)
	return parse_vet(text, pkg_dir, allocator), true
}
