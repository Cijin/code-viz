# Substrate — specification v0.1

Substrate is a desktop app that shows what your code does to the machine. It watches a project. After each successful build, it shows how the change affected execution, safety and memory. It runs beside the editor. You read it in a glance while you stay in flow.

- **Built with:** Odin + SDL3 (`vendor:sdl3`, SDL3_ttf).
- **Analyzes:** Odin first. Go second.
- **Platforms:** Linux x86-64 first, then macOS arm64. Windows is out of scope for v1 (see §12).

The visual design is in `docs/design/`. The mockups are HTML files. Read exact colors, sizes and layout from them (§8).

---

## 1. Goals and non-goals

Goals:

1. Show the consequences of each code change on the row of the code that caused it.
2. Encode every consequence as a shape. Text goes only in hover and lenses.
3. Update within 300 ms of a green build for glance data (T0), and within 2 s for block and lens data (T1).
4. Use deterministic metrics only: bytes, instruction counts, check sites.

Non-goals for v1:

- Wall-clock timing. At this scale it is noise.
- Failed builds. Substrate ignores them and keeps the last green snapshot.
- Editor plugins. v1 runs as a separate window (§8.6).
- Windows and PDB debug info.

---

## 2. Views

Substrate has three depths. Each depth answers in a different time budget.

| Depth | Mockup | Time to read | Content |
|---|---|---|---|
| Glance | `Main.dc.html` (right panel) | 0.5 s | One lane each for execution, memory, safety. One delta number and one shape strip per lane. |
| Blocks (primary) | `Blocks.dc.html` | 5 s | One row per changed code block. Columns: execution, safety, memory. |
| Lens | `Execution.dc.html`, `Memory.dc.html`, `Safety.dc.html` | study | One lane in depth. |

The Blocks view is the core of the product. Every consequence sits on the row of the code that caused it. The glance view and the lenses reuse the same row model and the same glyphs.

`Pipeline.dc.html` is an analysis board for the builder. It is not part of the app UI.

Navigation:

- Click a glance lane to open its lens.
- Click the build chip in the glance header to open Blocks.
- The tabs at the top of each lens switch between Glance, Blocks and the three lenses.

---

## 3. Visual vocabulary (fixed)

Do not add glyphs or colors without a spec change. Users learn the vocabulary once.

### 3.1 Colors

| Token | Hex | Use |
|---|---|---|
| `bg_desktop` | `#0d0f0e` | Area behind windows |
| `bg_lens` | `#111311` | Lens window background |
| `bg_window` | `#151816` | Glance panel background |
| `bg_panel` | `#171a18` | Panels inside lenses |
| `bg_lane` | `#1b1f1c` | Glance lane card |
| `bg_raised` | `#232824` | Chips, selected tab |
| `bg_code` | `#121513` | Code snippets |
| `line` | `#262b27` | Panel borders, row dividers |
| `line_strong` | `#3a423c` | Hover border, box outlines |
| `text` | `#ecebe4` | Primary text |
| `text_2` | `#aeb2a8` | Secondary text |
| `text_3` | `#8a8f85` | Captions, legends |
| `text_4` | `#5c625b` | Line numbers |
| `glyph_fill` | `#6c7a70` | ALU op glyph |
| `field_fill` | `#56625a` | Data bytes, before-bars |
| `cost` | `#f2a14a` | New or worse. Orange. |
| `gain` | `#5ea8ee` | Better, suggested fix. Blue. |
| `neutral_dot` | `#353b36` | No change in the build strip |

Color means attention only. Orange is cost, blue is gain, grey is no change. The sign (+/−) always carries the same meaning, so color is never the only signal.

### 3.2 Glyphs

| Glyph | Shape | Size (lens / glance) | Meaning |
|---|---|---|---|
| op | filled rounded rect | 11×20 / 8×14 | ALU or move instruction |
| mem | hollow rounded rect, 2 px stroke | 11×20 / 8×14 | Load or store instruction |
| branch | filled square rotated 45° | 12×12 / 8×8 | Conditional or unconditional jump |
| call | filled circle | 15 / 10 | call or ret |
| check | ring, 2 px stroke | 18 / 14 | Run-time check site (bounds, slice, type assertion) |
| check, removed | dashed ring, `text_4` | 18 / 14 | The optimizer removed this check |
| byte read | hollow bar | 9×18 | One byte loaded |
| byte written | filled bar | 9×18 | One byte stored |
| data byte | filled cell, `field_fill` | 14×14 / 44×56 | Struct byte that holds a field |
| padding byte | hatched `cost` at 135°, 1 px `cost` outline | same | Struct byte that holds padding |

Modifiers:

- **New:** the glyph uses `cost`. For hollow glyphs, only the stroke changes.
- **Changed:** 1.5 px dashed outline in `text`, 2 px offset.
- **Suggested fix:** `gain` stroke or fill.

### 3.3 Typography

- UI labels: IBM Plex Sans Condensed 400/500/600/700.
- Code, numbers and glyph labels: IBM Plex Mono 400/500/600.
- Bundle both TTF files in `assets/fonts/`. Both use the SIL Open Font License.
- Sizes: caps label 12 px (uppercase, 0.12 em tracking), body 14–15 px, code 12.5–13 px, lane delta 34 px, lens title 30 px.

### 3.4 Text rules

- Glance and Blocks views: no sentences. Use labels of one to three words, numbers and glyphs only.
- Lenses: short labels. Put an explanation in a hover tooltip, not on the surface.
- Tooltip text follows ASD-STE100 Simplified Technical English. Keep sentences to 25 words or fewer. Use simple tenses and active voice, with no filler words.

---

## 4. Architecture

```
 file watcher ──► builder ──► (green?) ──► analyzer pool T0 ──► snapshot store ──► differ ──► UI
                                  │                T1 ─────────────┘                   ▲
                                  └──────────────► T2 runner (cancelable) ─────────────┘
```

### 4.1 Threads

| Thread | Job | Blocking allowed |
|---|---|---|
| UI (main) | SDL event loop, layout, draw | No |
| Watcher | Poll project files for mtime changes every 250 ms. Debounce 300 ms. | Yes |
| Builder | Run the compiler as a child process. Report ok or fail. | Yes |
| Analyzer pool (2–4) | Run T0, then T1 analyzers on the green artifact. | Yes |
| T2 runner | Run the pinned test under Callgrind, ASan or DHAT. | Yes |

Rules:

1. The UI thread never waits on a child process or on disk.
2. Workers send results through `core:sync/chan`. They then wake the UI with `SDL_PushEvent` and a user event type.
3. The UI draws only on an event: new data, input or resize. When idle, it uses `SDL_WaitEvent`. Idle CPU use must be close to 0%.
4. A new green build cancels any running T2 job. Kill the child process and discard its partial results.
5. Each build writes to its own temp directory: `<cache>/builds/<build_id>/`. Keep the last 2 green builds. Delete the others.

### 4.2 Build command

Odin:

```
odin build <pkg_dir> -o:speed -debug -out:<cache>/builds/<id>/app
```

Go (v2):

```
go build -gcflags='all=-m -d=ssa/check_bce/debug=1' -o <cache>/builds/<id>/app <pkg>
```

Capture stderr for both. For Go, the `-m` and `check_bce` lines are analyzer input (§6.8).

Always analyze an optimized build that has debug info. A debug-only build misreports inlining and check sites.

---

## 5. Data model

Put these in `snapshot/types.odin`. Names are a proposal. Keep the shape.

```odin
Build_Id :: distinct u32

Source_Pos :: struct {
	file: string, // path relative to the project root
	line: i32,
}

Insn_Kind :: enum u8 { Op, Mem, Branch, Call }

Insn :: struct {
	kind: Insn_Kind,
	pos:  Source_Pos,
	text: string, // mnemonic and operands, for the "show asm" toggle
	cold: bool,   // true when the insn sits in a block that ends in a panic or trap call
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
}

Type_Layout :: struct {
	name:   string,
	pos:    Source_Pos,
	size:   int,
	align:  int,
	fields: []Field, // sorted by offset
}

Check_Kind :: enum u8 { Index, Slice, Dynamic_Array, Type_Assert, Matrix, Trap }

Check_Site :: struct {
	kind:    Check_Kind,
	pos:     Source_Pos,
	proc_:   string,
	removed: bool, // the source has a check here, but the optimized code does not
}

Opt_Out_Kind :: enum u8 { No_Bounds_Check, Transmute, Multi_Pointer, Raw_Ptr_Cast, Go_Unsafe }

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
	source:   map[string][]string, // file → lines, for the line mapping in §7
}
```

A `Delta` holds the result of `diff(prev, curr: ^Snapshot)`. Section §7 describes the diff.

---

## 6. Analyzers

Each analyzer is a procedure that takes an artifact path and returns part of a snapshot. Analyzers run external tools as child processes and parse their text output. Keep each parser in its own file with its own tests.

### 6.1 Type layout (T0)

- **Command:** `llvm-dwarfdump --debug-info <bin>`
- **Parse:** read each `DW_TAG_structure_type` that has a `DW_AT_name` and whose `DW_AT_decl_file` is under the project root. For each child `DW_TAG_member`, read `DW_AT_name`, `DW_AT_data_member_location` and the `DW_AT_byte_size` of its type.
- **Padding:** add the gaps between fields and the tail gap up to `size`.
- **Checked:** the author ran this on a C struct with the same layout. The output lists members with offsets `0x00, 0x04, 0x08, 0x10` and `DW_AT_byte_size (0x18)`.
- **Speed:** for large binaries, parse only the compile units of changed files. As an alternative, write a direct DWARF reader later.

### 6.2 Machine code by line (T1)

- **Command:** `llvm-objdump -d -l -M intel --no-show-raw-insn --no-leading-addr --disassemble-symbols=<sym> <bin>`
- **Parse:** a line that starts with `; <path>:<line>` sets the current source position. Each instruction line after it gets that position.
- **Checked:** the author ran this with clang output. Inlined code gets the line of the callee source.
- **Classify** by mnemonic:

| Kind | x86-64 | arm64 |
|---|---|---|
| Branch | `j*`, `jmp` | `b`, `b.*`, `cbz`, `cbnz`, `tbz`, `tbnz`, `br` |
| Call | `call`, `ret` | `bl`, `blr`, `ret` |
| Mem | any memory operand `[...]`, except `lea` | `ldr*`, `str*`, `ldp`, `stp`, `ldur`, `stur` |
| Op | everything else, including `lea` | everything else |

- **Cold code:** mark an instruction as cold if its basic block ends in a call to a check handler (§6.4).

### 6.3 Inlining (T0)

- **Command:** `llvm-dwarfdump --debug-info <bin>`. Use the same pass as §6.1.
- **Parse:** each `DW_TAG_inlined_subroutine` has a `DW_AT_abstract_origin` (the callee name) and sits inside the caller's `DW_TAG_subprogram`.
- Odin has no flag for LLVM optimization remarks. DWARF is the source of inlining data.

### 6.4 Check sites (T0)

Scan the disassembly for calls to these Odin runtime procedures. The names come from `base/runtime/error_checks.odin`:

- `bounds_check_error`, `bounds_check_error_loc`
- `slice_expr_error_hi`, `slice_expr_error_lo_hi`, and the `_loc` variants
- `multi_pointer_slice_expr_error`
- `dynamic_array_expr_error`, `dynamic_array_expr_error_loc`
- `matrix_bounds_check_error`
- `type_assertion_check*`
- `bounds_trap`

The symbol prefix in the binary is not confirmed. Run `llvm-nm` on a test build to find it. Match on the suffix.

Attribute each check to the source line of the call instruction. A check the source implies but the machine code lacks is `removed: true`. Detect removed checks in T1: an index or slice expression in the AST (§6.5) with no check site on its line.

Go: use the `-d=ssa/check_bce/debug=1` output. It reports each bounds check that the compiler did not remove, by line. Also scan for calls to `runtime.panicIndex*` and `runtime.panicSlice*`.

### 6.5 Opt-outs (T0)

- **Odin:** parse changed files with `core:odin/parser`. Report `#no_bounds_check` (on a block or a procedure), `transmute`, indexing through `[^]T`, and casts from `rawptr`.
- **Go:** parse with `go/ast`. Report imports and uses of package `unsafe`.

### 6.6 Symbol sizes (T0)

- **Command:** `llvm-nm -S --size-sort <bin>`. For Go, use `go tool nm -size <bin>`.

### 6.7 Vet (T1)

- **Odin:** `odin build <pkg> -vet`. Parse the diagnostics.
- **Go:** `go vet` and staticcheck.
- Show only new findings.

### 6.8 Go compiler diagnostics (T0, Go only)

- **Inlining:** lines with `can inline` and `inlining call to`.
- **Heap escapes:** lines with `escapes to heap` and `moved to heap`. These feed the memory column in the Blocks view.

### 6.9 T2: pinned test

The user pins one test procedure. T2 builds it as an optimized test binary with debug info, then runs:

| Metric | Command |
|---|---|
| Executed instructions, calls | `valgrind --tool=callgrind --callgrind-out-file=<f> <test_bin>`, then `callgrind_annotate <f>` |
| L1d and branch misses | add `--cache-sim=yes --branch-sim=yes` |
| Heap | `valgrind --tool=dhat --dhat-out-file=<f> <test_bin>` |
| Memory errors | `odin test <pkg> -sanitize:address` (Go: `go test -race`, `go test -asan`) |

The exact flags to keep the Odin test binary and to select one test are not confirmed. Check `odin help test` first.

Callgrind and DHAT run on Linux only. On macOS, T2 shows only the sanitizer result in v1.

---

## 7. Diff

### 7.1 Line mapping

An edit moves the lines below it. Without a mapping, every row below the edit looks changed.

1. For each changed file, run a Myers line diff between the previous and current source text.
2. Build `old_line → new_line` for unchanged lines.
3. Map every old `Source_Pos` through this table before you compare.

### 7.2 Per-line instruction diff

For each current line, compare its instructions with the instructions on the mapped old line:

1. Match instructions by kind, in order.
2. An unmatched current instruction is **new**.
3. A matched instruction whose operand text differs is **changed**.
4. An unmatched old instruction is **removed**. Count it in the Δ column. Do not draw it in v1.

If a callee was inlined in the old build and is a call in the new build, compare its instructions against the inlined copy in the caller. `Execution.dc.html` shows this case.

### 7.3 Types

- Match types by name and fields by name.
- Report the size delta and the padding delta.
- Suggest a reorder: sort fields by alignment (descending), keep declared order for ties, then compute the new size. Show the suggestion only if it saves bytes.
- Compute cache-line placement for the first 8 elements of an array of the type. Count elements that cross a 64-byte boundary.

### 7.4 Blocks

- A block is one statement, or one type declaration (multi-line).
- Get statement ranges from the parser (§6.5).
- A block is changed if any of its lines changed in the source diff, or if any consequence on its lines changed.
- The Blocks view lists changed blocks first, in source order, then the other blocks in the same procedure.

---

## 8. UI

### 8.1 Rendering

- Use `SDL_Renderer`. Draw rects with `SDL_RenderFillRect` and borders with `SDL_RenderRect`.
- Draw diamonds and circles with `SDL_RenderGeometry`. Cache circle meshes per radius.
- Draw hatching with an 8×8 texture, tiled with `SDL_RenderTextureTiled`, then clipped with `SDL_SetRenderClipRect`.
- Draw text with SDL3_ttf. Use `TTF_CreateRendererTextEngine`, and cache `TTF_Text` objects per string.
- Support HiDPI. Read `SDL_GetWindowDisplayScale` and scale all sizes from the mockups by it.

### 8.2 Layout

Take sizes from the mockups. They use CSS pixels at scale 1. Key values:

| Element | Value |
|---|---|
| Glance panel width | 468 |
| Lane card padding | 16 × 18, radius 8, gap 10 between lanes |
| Lens window | 1440 × 960 reference size, padding 24/32/28 |
| Block row | code column 520, safety column 150, execution and memory columns share the rest |
| Row height | 42 for one line, 22 per extra line + 20 |
| Byte grid cell (Memory lens) | 8 columns, gap 4, row height 56 |

Use flex-like stacking with fixed gaps. Do not write a general layout engine. Write one layout procedure per view.

### 8.3 Glance view

Lanes top to bottom: Execution, Memory, Safety. Each lane has:

- Caps label and the name of the main changed symbol.
- A delta number in `cost` or `gain`, 34 px, in a fixed 80 px column.
- One shape strip:
  - **Execution:** all instruction glyphs of the changed procedure, new ones in orange, plus the inline boxes.
  - **Memory:** the previous and current byte strips, stacked.
  - **Safety:** check rings now → check rings after the fix.
- A strip of "no change" chips for the quiet signals: stack, heap, opt-out, vet.
- A strip for the last 16 green builds: three dots per build (E, M, S).
- A glyph legend at the bottom.

If a lane has no change, collapse it to its caps label and a grey `=`.

### 8.4 Blocks view

Match `Blocks.dc.html`. One header row, one row per block, and a Σ row at the bottom. The selected block has a 3 px `cost` left bar and a 10% `cost` tint.

### 8.5 Lenses

Match the three lens mockups. The Execution lens has a "show asm" button. It swaps glyph cells for instruction text in the same rows.

### 8.6 Selection without an editor plugin

v1 cannot read the editor selection. Pin the block with the largest change automatically. A click on a row in Substrate pins that row. An editor bridge through a language server is v2 or later.

### 8.7 Hover

Hovering a glyph, row or chip shows a tooltip after 400 ms. It has up to three short sentences: what the glyph is, the cause, and the tool that measured it.

---

## 9. Budgets

| Item | Budget |
|---|---|
| T0 after a green build | < 300 ms for a 20 k-line project |
| T1 after a green build | < 2 s |
| UI frame | < 4 ms |
| Idle CPU | ~0% |
| Memory for 2 snapshots | < 200 MB |

Measure each budget in a test on the fixtures. Print the timings to the log. Do not show them in the UI.

---

## 10. Milestones

Build them in order. Each milestone ends with its tests passing and a commit.

| # | Scope | Acceptance |
|---|---|---|
| M0 | SDL3 window, fonts, color tokens, glyph drawing, static glance view from a hard-coded snapshot | A screenshot matches the right panel of `Main.dc.html` in layout, colors and glyphs |
| M1 | Watcher, builder, build cache, last-green logic, status dot | Editing a fixture file triggers one build. A failed build does not change the view. |
| M2 | Type layout analyzer (§6.1), type diff (§7.3), Memory lane, Memory lens | `fixtures/expected.md` memory table passes exactly |
| M3 | Disassembly by line (§6.2), inlining (§6.3), line mapping (§7.1), per-line diff (§7.2), Execution lane, Execution lens | New instructions map to the `flags` and `return` lines of v214 |
| M4 | Check sites (§6.4), opt-outs (§6.5), Safety lane, Safety lens | v214 has one more check site than v213, on the `flags` line |
| M5 | Blocks view (§7.4, §8.4) | The Blocks view of v213 → v214 matches `Blocks.dc.html` in structure |
| M6 | T2 runner (§6.9), cancel on new build, scenario bars | Callgrind numbers appear for `decode_10k_frames`. A new build cancels the run. |
| M7 | Go front end (§4.2, §6.4, §6.8) | A Go port of the fixture gives the same memory table |

---

## 11. Items to verify first

The author could not run Odin while writing this spec. Before M2, confirm these facts:

1. The fixtures compile with the current Odin release.
2. `-o:speed -debug` together emit DWARF with inlining records on Linux.
3. The symbol names of Odin runtime check procedures in the binary (§6.4).
4. How Odin names user procedures in the symbol table, for example `frame.parse_header`.
5. Which Odin flags keep the test executable and select one test (§6.9).
6. Whether the Odin calling convention returns a 24-byte struct through a hidden pointer on x86-64 and arm64. The Execution lens mockup assumes it does.
7. `vendor:sdl3` and its `ttf` binding are in the installed Odin version.

Record each answer in `docs/VERIFIED.md`.

---

## 12. Open questions

1. **Platform order:** Linux first, or macOS first? T2 is weaker on macOS.
2. **Go timing:** Go needs a different disassembler and different diagnostics. Plan it after M6, not in parallel.
3. **Windows:** Odin on Windows writes PDB. Supporting it needs a PDB reader for §6.1 and §6.3.
4. **Scope of the watch:** one package, or a whole workspace with many packages?
