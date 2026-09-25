# Design files

The `mockups/` files are HTML sources from a design canvas. They are a reference, not code to port. SDL3 draws the real UI.

| File | View | Reference size |
|---|---|---|
| `Main.dc.html` | Glance panel (right) beside an editor (left) | 1440 × 900 |
| `Blocks.dc.html` | Consequences by block: the primary view | 1440 × 960 |
| `Execution.dc.html` | Execution lens | 1440 × 960 |
| `Memory.dc.html` | Memory lens | 1440 × 960 |
| `Safety.dc.html` | Safety lens | 1440 × 960 |
| `Pipeline.dc.html` | Analysis board: tools per lane and tier. Not app UI. | 1440 × 1260 |

How to read the files:

- Sizes and colors are in inline `style="…"` attributes and in the `<style>` block inside `<helmet>`. The values are CSS pixels at scale 1.
- The glyph classes (`.i.alu`, `.i.mem`, `.i.br`, `.i.call`, `.pp`, `.by`, `.pad`) define the exact glyph sizes. SPEC §3.2 lists the same values.
- The `<script type="text/x-dc">` block at the end holds the sample data for rows and strips.
- The numbers in the mockups are illustrative. Only the memory values are exact. Use `fixtures/expected.md` for tests.

Put PNG exports of each artboard in `png/`.
