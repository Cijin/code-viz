package analyze

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// External tools (CLAUDE.md): llvm-dwarfdump, llvm-objdump, llvm-nm from
// LLVM 17+. Homebrew's LLVM is keg-only, so look beyond PATH.

LLVM_DIRS := []string{
	"/opt/homebrew/opt/llvm/bin",
	"/usr/local/opt/llvm/bin",
	"/usr/lib/llvm-23/bin", "/usr/lib/llvm-22/bin", "/usr/lib/llvm-21/bin", "/usr/lib/llvm-20/bin",
	"/usr/lib/llvm-19/bin", "/usr/lib/llvm-18/bin", "/usr/lib/llvm-17/bin",
}

// Absolute path of `name`, or "" when it cannot be found. Cached.
find_tool :: proc(name: string) -> string {
	@(static) cache: map[string]string
	@(static) mu: sync.Mutex
	sync.guard(&mu)
	if cache == nil do cache = make(map[string]string, runtime.heap_allocator())
	if p, ok := cache[name]; ok do return p
	found := ""
	path_env := os.get_env("PATH", context.temp_allocator)
	search: for dir in strings.split(path_env, ":", context.temp_allocator) {
		candidate := fmt.tprintf("%s/%s", dir, name)
		if os.exists(candidate) {
			found = candidate
			break search
		}
	}
	if found == "" {
		for dir in LLVM_DIRS {
			candidate := fmt.tprintf("%s/%s", dir, name)
			if os.exists(candidate) {
				found = candidate
				break
			}
		}
	}
	// The cache lives for the whole process, so it uses the heap directly.
	cache[strings.clone(name, runtime.heap_allocator())] = strings.clone(found, runtime.heap_allocator())
	return cache[name]
}

// Runs a tool and returns its stdout (allocated with `allocator`).
run_tool :: proc(argv: []string, allocator := context.allocator) -> (out: string, ok: bool) {
	state, stdout, stderr, err := os.process_exec({command = argv}, allocator)
	delete(stderr, allocator)
	if err != nil || !state.success {
		delete(stdout, allocator)
		return "", false
	}
	return string(stdout), true
}

// Runs a command capturing stdout and stderr in the temp allocator,
// whatever the exit code.
os_process_exec :: proc(argv: []string) -> (state: os.Process_State, stdout, stderr: []byte, failed: bool) {
	st, out, errb, err := os.process_exec({command = argv}, context.temp_allocator)
	return st, out, errb, err != nil
}

// Where the DWARF for `artifact` lives: macOS keeps it in the .dSYM bundle
// (docs/VERIFIED.md §2); ELF keeps it in the binary.
dwarf_path :: proc(artifact: string, allocator := context.allocator) -> string {
	when ODIN_OS == .Darwin {
		base := artifact
		if i := strings.last_index_byte(artifact, '/'); i >= 0 do base = artifact[i + 1:]
		dsym := fmt.aprintf("%s.dSYM/Contents/Resources/DWARF/%s", artifact, base, allocator = allocator)
		if os.exists(dsym) do return dsym
	}
	return strings.clone(artifact, allocator)
}
