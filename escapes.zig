const std = @import("std");
const cc = std.ascii.control_code;

pub const Escape = struct {
    len: u8,
    kind: union(enum) {
        none: void,
        backspace: void,
        incomplete_sequence: void,
        ignore_for_now: void,
        unimplemented_sequence: void,
        display_attrs: [16]u8,
    },
};

pub fn parseEscape(buf: []const u8) Escape {
    std.debug.assert(buf.len > 0);
    switch (buf[0]) {
        cc.BS => return .{ .len = 1, .kind = .backspace },
        cc.ESC => {
            if (buf.len == 1) return .{ .len = 1, .kind = .incomplete_sequence };
            if (buf[1] == '[') {
                var i: u8 = 2;
                while (true) : (i += 1) {
                    if (i == buf.len)
                        return .{ .len = i, .kind = .incomplete_sequence };
                    switch (buf[i]) {
                        '0' ... '9' => {}, // ignore for now
                        ';' => {}, // ignore for now
                        else => return .{ .len = i + 1, .kind = .{ .display_attrs = undefined } },
                    }
                }
            } else {
                std.log.warn("unhandled char after esc (0x1b) character {}", .{buf[1]});
                return .{ .len = 2, .kind = .unimplemented_sequence };
            }
        },
        '\r' => {
            return .{ .len = 1, .kind = .ignore_for_now };
        },
        else => {
            return .{ .len = 1, .kind = .none};
        }
    }
}
