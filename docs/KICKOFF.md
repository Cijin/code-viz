# Hand-off to Claude Code

## 1. Prepare the repository

1. Unzip this package into the root of the repository. If the repository already has a `CLAUDE.md`, merge the two files.
2. Open the Design canvas. Export each artboard as PNG. Save the files to `docs/design/png/` with the same names as the mockups, for example `Blocks.png`.
3. Install the tools: Odin, SDL3, SDL3_ttf, LLVM (17 or later) and valgrind.
4. Commit: `git add . && git commit -m "Add Substrate spec and design"`.

## 2. First session: verify, then M0

Start Claude Code in the repository root. Use plan mode, then paste this prompt:

```
Read CLAUDE.md, docs/SPEC.md and every file in docs/design/.

Step 1: Work through SPEC §11 ("Items to verify first"). Build both fixtures,
inspect the binaries with llvm-nm, llvm-dwarfdump and llvm-objdump, and record
each answer in docs/VERIFIED.md. If an answer contradicts the spec, stop and
tell me before you change the spec.

Step 2: Plan milestone M0 (SPEC §10). Show me the plan with the file layout
and the procedures you will write. Wait for my approval before you write code.
```

## 3. Later sessions: one milestone each

```
Read CLAUDE.md, docs/SPEC.md and docs/VERIFIED.md.
Plan milestone M<N> from SPEC §10. Show the plan and wait for approval.
After approval, implement it, run the tests, compare against fixtures/expected.md
where it applies, and commit.
```

## 4. Tips

- Keep one milestone per session. A long session loses detail.
- For UI milestones, ask Claude Code to add a `--screenshot <file>` flag. The flag renders one frame, saves it with `SDL_RenderReadPixels`, and exits. Claude Code can then compare the result with the PNG export. Set `SDL_VIDEO_DRIVER=offscreen` to run it without a display.
- If the design changes, edit the canvas, export the PNGs again, copy the new `.dc.html` files into `docs/design/mockups/`, and tell Claude Code which artboard changed.
