const std = @import("std");

const CharGrid = @This();

width: u16,
height: u16,
ptr: [*]u8,

pub fn init(allocator: *std.mem.Allocator, width: u16, height: u16) error{OutOfMemory}!CharGrid {
    const slice = try allocator.alloc(u8, @intCast(u32, width) * @intCast(u32, height));
    std.mem.set(u8, slice, ' ');
    return CharGrid{
        .width = width,
        .height = height,
        .ptr = slice.ptr
    };
}

pub fn getRowPtr(self: CharGrid, row: u16) [*]u8 {
    return self.ptr + (row * self.width);
}

pub fn copyRow(self: CharGrid, row: u16, chars: []const u8) void {
    const row_ptr = self.getRowPtr(row);
    var col: usize = 0;
    var chars_index: usize = 0;
    while (chars_index < chars.len) {

        // temporary decoding
        if (chars[chars_index] == '\r') {
            // ignore these for now
            chars_index += 1;
        } else if (atSequence(chars, chars_index, &[_]u8 { 0x08, 0x20, 0x08})) {
            if (col >= 1) {
                col -= 1;
            } else {
                std.log.warn("shell sent backspace without any characters? is that ok?", .{});
            }
            chars_index += 3;
        } else {
            if (col < self.width) {
                row_ptr[col] = chars[chars_index];
            }
            col += 1;
            chars_index += 1;
        }
    }
    while (col < self.width) : (col += 1) {
        row_ptr[col] = ' ';
    }
}

fn atSequence(chars: []const u8, index: usize, seq: []const u8) bool {
    std.debug.assert(seq.len > 0);
    if (index + seq.len > chars.len)
        return false;
    var i: usize = 0;
    while (true) {
        if (chars[index + i] != seq[i])
            return false;
        i += 1;
        if (i == seq.len) return true;
    }
}
