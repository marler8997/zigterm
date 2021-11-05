const std = @import("std");
const escapes = @import("escapes.zig");

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

        const escape = escapes.parseEscape(chars[chars_index..]);
        switch (escape.kind) {
            .none => {
                if (col < self.width) {
                    row_ptr[col] = chars[chars_index];
                }
                col += 1;
            },
            .backspace => {
                if (col == 0) {
                    std.log.warn("got backspace at beginning of line?", .{});
                } else {
                    col -= 1;
                }
            },
            .incomplete_sequence => {
                std.debug.assert(chars_index + escape.len == chars.len);
                if (col < self.width) {
                    row_ptr[col] = '!'; // TODO: maybe something better here?
                }
                col += 1;
            },
            .ignore_for_now => {},
            .unimplemented_sequence => {
                if (col < self.width) {
                    row_ptr[col] = '?';
                }
                col += 1;
            },
            .display_attrs => |attrs| {
                _ = attrs;
                std.log.info("TODO: handle display attr escape sequence (len = {})", .{escape.len});
            },
        }
        chars_index += escape.len;
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
