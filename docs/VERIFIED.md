# Verified facts (SPEC §11)

Checked on 2026-09-25, on macOS arm64 with Odin `dev-2026-09:aefa0a7d2` and Homebrew LLVM 23.1.0 (`/opt/homebrew/opt/llvm/bin`, not on `PATH`). Linux x86-64 is not checked yet.

## 1. Fixtures compile — yes

`odin build fixtures/frame_v213 -o:speed -debug -build-mode:test` builds both fixtures with no source changes. The fixtures have no `main`, so they only build as a test binary (`-build-mode:test`) or an object.

## 2. `-o:speed -debug` emits inlining records — yes (macOS)

- The DWARF goes into `<out>.dSYM/Contents/Resources/DWARF/<name>`, not the binary. Tools need that path: `llvm-dwarfdump <out>.dSYM`, `llvm-objdump --dsym=<dwarf file>`, `llvm-symbolizer --obj=<dwarf file>`.
- `DW_TAG_inlined_subroutine` entries exist, with `DW_AT_abstract_origin ("frame::parse_header")` and `("frame::read_frame")`.
- `Frame_Header` layout matches `expected.md`: `DW_AT_byte_size` 0x10 (v213) and 0x18 (v214), `DW_AT_alignment` 8. `DW_AT_name` is `frame::Frame_Header` (package-qualified).

## 3. Runtime check symbols — CONTRADICTS §6.4

- Names are package-qualified with a Mach-O underscore: `_runtime::bounds_check_error.handle_error-0`, `_runtime::slice_handle_error`, `_runtime::slice_expr_error_hi`, `_runtime::slice_expr_error_lo_hi`, `_runtime::type_assertion_check2_*.handle_error-0`.
- At `-o:speed`, `bounds_check_error` and `slice_expr_error_*` are **inlined**. The only remaining calls go to the cold `handle_error` / `slice_handle_error` procs. Machine code has a compare and a conditional branch into a shared block that makes that call.
- **One call can serve many checks.** In a standalone (non-inlined) proc, each check still gets its own call. After inlining into a loop, checks merge or disappear.
- `llvm-objdump -l` attributes the handler call to `error_checks.odin`, not to user code. To reach the user line, resolve the address of the **conditional branch** with `llvm-symbolizer --inlining` and take the innermost frame that is in the project.
- **Fixture result:** both v213 and v214 have 2 check sites, both in `decode_10k_frames` (the `buf[off] = 1` line and the `buf[off+1:off+5]` slice line). `parse_header` is inlined into the test and all of its checks are proven safe and removed, including the `flags` check. `expected.md` ("one more check site on the `flags` line") **does not hold** for the optimized test binary.

## 4. User procedure names — `_<pkg>::<name>`

- For example `_frame::decode_10k_frames`. File-private procs are `_<pkg>::[<file>.odin]::<name>`. Nested procs are `outer.inner-N`.
- `llvm-objdump --disassemble-symbols` cannot match names with `[...]`. Disassemble the section and cut out the symbol instead.
- **Odin emits no code for unreachable procs.** In the fixtures, `parse_header` and `read_frame` exist only as inlined code in `decode_10k_frames`. They have no symbol, even in `-build-mode:obj`.

## 5. Keep the test executable and select one test

- `odin build <pkg> -build-mode:test -out:<bin>` builds the test binary without running it.
- `-define:ODIN_TEST_NAMES=<pkg>.<test>` selects a test (comma-separated for several).
- `odin test <pkg> -keep-executable` runs the tests and keeps the binary.
- On macOS, the first launch of each new binary costs about 300 ms (a system check). Later launches of the same file cost about 0 ms.

## 6. 24-byte struct return — hidden pointer (arm64)

- `#force_no_inline` procs at `-o:speed` show that a 16-byte `{u8, u32, u64}` returns in `x0`/`x1`.
- A 24-byte `{u8, u32, u8, u64}` is written through `x8` (the arm64 indirect result register) with `strb`/`str`/`stur` stores.
- x86-64 is not checked yet.

## 7. `vendor:sdl3` and `ttf` bindings — yes

- `vendor:sdl3` and `vendor:sdl3/ttf` (`sdl3_ttf.odin`, `sdl3_textengine.odin`) exist.
- Homebrew: `sdl3` 3.4.16 and `sdl3_ttf` 3.2.2 (installed during verification).
- `valgrind` is not available on macOS arm64.

## Decision: analyze an `-o:minimal -debug` build (deviates from §4.2)

The spec's check-site model (§6.4) and the `expected.md` Safety and Execution assertions need `parse_header` to exist as its own procedure. The user chose to keep the spec's expectations, so the analysis build uses `-o:minimal`:

- At `-o:minimal`, `parse_header`, `read_frame` and `decode_10k_frames` all keep their symbols.
- Check handlers stay real calls (`_runtime::bounds_check_error`, `_runtime::slice_expr_error_lo_hi`).
- `llvm-objdump -l` attributes each call to the user line.
- `parse_header` check calls: v213 = 3 (lines 23, 24, 25), v214 = 4 (lines 25, 26, **27**, 28). Line 27 is `flags := buf[offset+5]`, so `expected.md` holds exactly.
- At `-o:size` and `-o:speed`, both procs are inlined into the test and their checks are removed. No other Odin flag disables inlining.

Build command: `odin build <pkg> -o:minimal -debug -build-mode:test -out:<cache>/builds/<id>/app`. The fixtures have no `main`, so they build in test mode.
