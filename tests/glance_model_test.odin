package tests

import "core:testing"
import snap "../src/snapshot"

@(test)
glyph_shorthand_test :: proc(t: ^testing.T) {
	items := snap.parse_glyph_shorthand("a b m +a ~m +c", context.temp_allocator)
	testing.expect_value(t, len(items), 6)
	testing.expect_value(t, items[0], snap.Glyph_Item{.Op, .Plain})
	testing.expect_value(t, items[2], snap.Glyph_Item{.Mem, .Plain})
	testing.expect_value(t, items[3], snap.Glyph_Item{.Op, .New})
	testing.expect_value(t, items[4], snap.Glyph_Item{.Mem, .Changed})
	testing.expect_value(t, items[5], snap.Glyph_Item{.Call, .New})
}

@(test)
cell_shorthand_test :: proc(t: ^testing.T) {
	cells := snap.parse_cell_shorthand("fpn", context.temp_allocator)
	testing.expect_value(t, len(cells), 3)
	testing.expect_value(t, cells[0], snap.Byte_Cell.Data)
	testing.expect_value(t, cells[1], snap.Byte_Cell.Padding)
	testing.expect_value(t, cells[2], snap.Byte_Cell.New_Data)
}

// The M0 glance model mirrors Main.dc.html's sample data.
@(test)
sample_glance_test :: proc(t: ^testing.T) {
	m := snap.sample_glance(context.temp_allocator)
	testing.expect_value(t, len(m.exec.glyphs), 29)
	testing.expect_value(t, len(m.memory.old_cells), 16)
	testing.expect_value(t, len(m.memory.new_cells), 24)
	testing.expect_value(t, len(m.builds), 16)
	testing.expect(t, m.builds[15].current)
	testing.expect_value(t, m.memory.delta, 8)
}
