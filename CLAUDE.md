# Substrate

This is a desktop app, written in Odin with SDL3. It shows how each successful build changes the execution, safety and memory of the program you are writing. It analyzes Odin now and Go later.

## Read first

- `docs/SPEC.md`: the full specification. It is the source of truth.
- `docs/design/mockups/*.dc.html`: the visual design as HTML mockups. Take exact colors, sizes and layout from the inline styles.
- `docs/design/png/`: PNG exports of the mockups, if present. Open them to see the target.
- `fixtures/`: a before/after Odin package pair, and `fixtures/expected.md` with the expected deltas.

## Rules

- Build one milestone at a time (SPEC §10). Plan first, then implement, then run the tests, then commit.
- The UI thread never blocks. Workers talk to the UI through channels plus `SDL_PushEvent`.
- The UI draws only on events. Idle CPU use must be close to 0%.
- Use only the glyphs and colors in SPEC §3. Do not add new ones.
- No sentences in the Blocks view. Explanations go in tooltips only.
- The Glance view was removed at the user's request: one window with the Blocks, Execution, Memory and Safety tabs, opening on Blocks.
- No wall-clock timing in the UI. Show bytes, instruction counts and check sites only.
- Parse external tool output in small, separate procedures, each with a test on captured sample output.
- If a fact in SPEC §11 is not confirmed yet, confirm it before code depends on it. Record the result in `docs/VERIFIED.md`.

## Commands

- Build: `odin build src -out:build/substrate -o:speed -debug` (without `-o:speed`, `-debug` means `-o:none` and analysis is ~5× slower)
- Run: `./build/substrate <project_dir>`
- Screenshot (one frame, then exit): `./build/substrate --screenshot out.bmp <project_dir>`
- Test: `odin test tests`
- LLVM tools on this Mac are keg-only: `/opt/homebrew/opt/llvm/bin` (not on `PATH`).
- The analysis build is `-o:minimal -debug -build-mode:test` (see `docs/VERIFIED.md`).

## External tools

`llvm-objdump`, `llvm-dwarfdump` and `llvm-nm` (LLVM 17 or later), `valgrind` (Linux), SDL3 and SDL3_ttf shared libraries.
