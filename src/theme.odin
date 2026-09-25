package main

// SPEC §3.1 color tokens. Do not add colors without a spec change; the few
// extra shades in the mockups map to the nearest token.

Color :: struct {
	r, g, b, a: u8,
}

BG_DESKTOP  :: Color{0x0d, 0x0f, 0x0e, 0xff}
BG_LENS     :: Color{0x11, 0x13, 0x11, 0xff}
BG_WINDOW   :: Color{0x15, 0x18, 0x16, 0xff}
BG_PANEL    :: Color{0x17, 0x1a, 0x18, 0xff}
BG_LANE     :: Color{0x1b, 0x1f, 0x1c, 0xff}
BG_RAISED   :: Color{0x23, 0x28, 0x24, 0xff}
BG_CODE     :: Color{0x12, 0x15, 0x13, 0xff}
LINE        :: Color{0x26, 0x2b, 0x27, 0xff}
LINE_STRONG :: Color{0x3a, 0x42, 0x3c, 0xff}
TEXT        :: Color{0xec, 0xeb, 0xe4, 0xff}
TEXT_2      :: Color{0xae, 0xb2, 0xa8, 0xff}
TEXT_3      :: Color{0x8a, 0x8f, 0x85, 0xff}
TEXT_4      :: Color{0x5c, 0x62, 0x5b, 0xff}
GLYPH_FILL  :: Color{0x6c, 0x7a, 0x70, 0xff}
FIELD_FILL  :: Color{0x56, 0x62, 0x5a, 0xff}
COST        :: Color{0xf2, 0xa1, 0x4a, 0xff}
GAIN        :: Color{0x5e, 0xa8, 0xee, 0xff}
NEUTRAL_DOT :: Color{0x35, 0x3b, 0x36, 0xff}

with_alpha :: proc(c: Color, a: f32) -> Color {
	return Color{c.r, c.g, c.b, u8(clamp(a, 0, 1) * 255)}
}

// SPEC §3.3 type scale (CSS px at scale 1).
CAPS_SIZE     :: f32(12)
CAPS_TRACKING :: f32(0.12) // em
LANE_DELTA    :: f32(34)
LENS_TITLE    :: f32(30)

// SPEC §8.2 / Main.dc.html layout values.
GLANCE_W        :: f32(468)
GLANCE_H        :: f32(860)
LANE_PAD_Y      :: f32(16)
LANE_PAD_X      :: f32(18)
LANE_RADIUS     :: f32(8)
LANE_GAP        :: f32(10)
LANE_ROW_GAP    :: f32(12)
LANE_DELTA_COL  :: f32(80)
LANE_DELTA_GAP  :: f32(16)
