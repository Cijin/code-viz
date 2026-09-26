package main

import "core:fmt"
import snap "snapshot"

// Click targets and small formatting helpers shared by the views.

Action :: enum u8 {
	None,
	Select_Block,
	Open_Blocks,
	Open_Execution,
	Open_Memory,
	Open_Safety,
}

Hit :: struct {
	rect:   Rect,
	action: Action,
	index:  int, // Select_Block: the row
}

format_delta :: proc(v: int, unit := "") -> string {
	sep := unit == "" ? "" : " "
	switch {
	case v > 0: return fmt.tprintf("+%d%s%s", v, sep, unit)
	case v < 0: return fmt.tprintf("−%d%s%s", -v, sep, unit)
	}
	return "="
}

delta_color :: proc(v: int) -> Color {
	return v > 0 ? COST : (v < 0 ? GAIN : TEXT_3)
}

status_color :: proc(s: snap.Build_Status) -> Color {
	switch s {
	case .Ok:       return TEXT_2
	case .Building: return TEXT_4
	case .Failed:   return COST
	}
	return TEXT_2
}
