const std = @import("std");

pub fn main() void {
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        //std.debug.warn("progress {}\r", .{i});
        std.debug.warn("progress {}\r", .{12 - i});
        std.time.sleep(std.time.ns_per_s);
    }
}
