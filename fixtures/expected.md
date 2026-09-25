# Expected deltas: frame_v213 → frame_v214

Use these as acceptance tests. Only the memory values are exact. The execution and safety values depend on the compiler version, so the tests assert direction and location, not exact counts.

## Memory (exact, x86-64 and arm64)

| Type | Build | Size | Align | Fields (name @ offset : size) | Padding bytes |
|---|---|---|---|---|---|
| `Frame_Header` | v213 | 16 | 8 | kind @0:1, length @4:4, stream_id @8:8 | 3 (1–3) |
| `Frame_Header` | v214 | 24 | 8 | kind @0:1, length @4:4, flags @8:1, stream_id @16:8 | 10 (1–3, 9–15) |
| `Frame_Header` | suggested | 16 | 8 | kind @0:1, flags @1:1, length @4:4, stream_id @8:8 | 2 (2–3) |

Cache lines (64 B), first 8 elements of `[dynamic]Frame_Header`:

- v213 and suggested: 2 lines, no element spans two lines.
- v214: 3 lines. Elements 2 and 5 span two lines.

For 10,000 elements: v213 uses 160,000 B (2,500 lines). v214 uses 240,000 B (3,750 lines).

The author checked the v214 offsets with an equivalent C struct and `llvm-dwarfdump`. They match: 0, 4, 8, 16, size 0x18.

## Safety (direction and location)

- `parse_header` in v214 has one more run-time check site than in v213.
- The new site maps to the line `flags := buf[offset+5]`.
- The number of opt-outs (`#no_bounds_check`, `transmute`, `[^]T`) does not change: 0 → 0.

## Execution (direction and location)

- `parse_header` in v214 has more instructions than in v213.
- The added instructions map to the `flags` line and to the `return` line.
- Inlining of `parse_header` into `read_frame` may or may not change. Report what DWARF says. Do not assert it.
