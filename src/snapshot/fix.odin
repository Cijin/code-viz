package snapshot

import "core:strings"

// Applies a suggested field order to the struct declared at `decl_line`
// (1-based) in `text`. Only the field lines move; comments, blank lines and
// formatting stay where they are. Returns false if the declaration does not
// match the expected fields (the file changed since the build).
reorder_struct_source :: proc(text: string, decl_line: int, order: []string, allocator := context.allocator) -> (string, bool) {
	lines := strings.split(text, "\n", context.temp_allocator)
	if decl_line < 1 || decl_line > len(lines) do return "", false
	if !strings.contains(lines[decl_line - 1], "struct") do return "", false

	// Field lines between the opening line and the matching closing brace.
	slots := make([dynamic]int, context.temp_allocator)
	by_name := make(map[string]string, context.temp_allocator)
	depth := strings.count(lines[decl_line - 1], "{") - strings.count(lines[decl_line - 1], "}")
	i := decl_line
	for ; i < len(lines) && depth > 0; i += 1 {
		l := lines[i]
		t := strings.trim_space(l)
		if depth == 1 {
			if colon := strings.index_byte(t, ':'); colon > 0 && !strings.has_prefix(t, "//") {
				name := strings.trim_space(t[:colon])
				append(&slots, i)
				by_name[name] = l
			}
		}
		depth += strings.count(l, "{") - strings.count(l, "}")
	}
	if len(slots) != len(order) do return "", false
	for name in order do if name not_in by_name do return "", false

	for name, k in order do lines[slots[k]] = by_name[name]
	return strings.join(lines, "\n", allocator), true
}
