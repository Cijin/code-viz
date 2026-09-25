package frame

// Fixture: build 214 (after). Adds `flags` to the struct and to the wire header.
// Wire header: kind(1) length(4) flags(1) stream_id(8) = 14 bytes.
// Not compiled by the author. Build it first and fix syntax if the compiler rejects it.

import "core:encoding/endian"
import "core:testing"

HEADER_SIZE :: 14

Frame_Header :: struct {
	kind:      u8,
	length:    u32,
	flags:     u8,
	stream_id: u64,
}

Frame :: struct {
	header: Frame_Header,
	body:   []u8,
}

parse_header :: proc(buf: []u8, offset: int) -> Frame_Header {
	kind      := buf[offset]
	length    := endian.unchecked_get_u32le(buf[offset+1:offset+5])
	flags     := buf[offset+5]
	stream_id := endian.unchecked_get_u64le(buf[offset+6:offset+14])
	return {kind, length, flags, stream_id}
}

read_frame :: proc(buf: []u8, offset: int) -> Frame {
	header := parse_header(buf, offset)
	body   := buf[offset+HEADER_SIZE:][:int(header.length)]
	return {header, body}
}

@(test)
decode_10k_frames :: proc(t: ^testing.T) {
	BODY :: 4
	N    :: 10_000
	buf := make([]u8, N * (HEADER_SIZE + BODY))
	defer delete(buf)
	headers := make([dynamic]Frame_Header, 0, N)
	defer delete(headers)
	for i in 0 ..< N {
		off := i * (HEADER_SIZE + BODY)
		buf[off] = 1
		endian.unchecked_put_u32le(buf[off+1:off+5], BODY)
		append(&headers, read_frame(buf, off).header)
	}
	testing.expect_value(t, len(headers), N)
}
