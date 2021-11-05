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
    var i: u16 = 0;
    while (true) : (i += 1) {
        if (i == self.width) return;
        if (i == chars.len) break;
        row_ptr[i] = chars[i];
    }
    while (i < self.width) : (i += 1) {
        row_ptr[i] = ' ';
    }
}
