const std = @import("std");
const testing = std.testing;
const cc = std.ascii.control_code;

pub const Escape = struct {
    len: u8,
    kind: Kind,

    pub const Kind = union(enum) {
        none: void,
        backspace: void,
        incomplete_sequence: void,
        ignore_for_now: void,
        unimplemented_sequence: void,
        csi: Csi,
    };

    pub const Csi = struct {
        action: u8,
        count: u4,
        attrs: [16]u8,
        too_many: bool,
        pub fn attrSlice(self: *const Csi) []const u8 {
            return self.attrs[0 .. self.count];
        }
    };
};

const CSI = 0x9b;

pub fn parseEscape(buf: []const u8) Escape {
    std.debug.assert(buf.len > 0);
    switch (buf[0]) {
        cc.BS => return .{ .len = 1, .kind = .backspace },
        cc.ESC => {
            if (buf.len == 1) return .{ .len = 1, .kind = .incomplete_sequence };
            if (buf[1] == '[')
                return parseCsi(buf, 1);
            std.log.warn("unhandled char after esc (0x1b) character {}", .{buf[1]});
            return .{ .len = 2, .kind = .unimplemented_sequence };
        },
        //'\r' => {
        //    return .{ .len = 1, .kind = .ignore_for_now };
        //},
        CSI => return parseCsi(buf, 0),
        else => {
            return .{ .len = 1, .kind = .none};
        },
    }
}

fn parseCsi(buf: []const u8, extra_char: u1) Escape {
    switch (extra_char) {
        0 => std.debug.assert(buf[0] == CSI),
        1 => {
            std.debug.assert(buf[0] == cc.ESC);
            std.debug.assert(buf[1] == '[');
        },
    }
    var result = Escape {
        .len = undefined,
        .kind = .{ .csi = .{
            .action = undefined,
            .count = 0,
            .attrs = undefined,
            .too_many = false,
        }},
    };
    result.kind.csi.attrs[0] = 0;
    var i: u8 = 1 + @intCast(u8, extra_char);
    while (true) : (i += 1) {
        if (i == buf.len) {
            result.len = i;
            result.kind = .incomplete_sequence;
            return result;
        }

        switch (buf[i]) {
            '0' ... '9' => |c| {
                result.kind.csi.attrs[result.kind.csi.count] *= 10;
                result.kind.csi.attrs[result.kind.csi.count] += c - '0';
            },
            ';' => {
                result.kind.csi.count += 1;
                if (result.kind.csi.count == 16)
                    break;
                result.kind.csi.attrs[result.kind.csi.count] = 0;
            },
            else => |action| {
                if (0 != result.kind.csi.attrs[result.kind.csi.count]) {
                    result.kind.csi.count += 1;
                }
                result.len = i + 1;
                result.kind.csi.action = action;
                return result;
            },
        }
    }
    @panic("todo");
}

test {
    try testing.expectEqual(Escape{ .len = 1, .kind = .incomplete_sequence }, parseCsi("\x9b", 0));
    try testing.expectEqual(Escape{ .len = 2, .kind = .incomplete_sequence }, parseCsi("\x9b0", 0));
    try testing.expectEqual(Escape{ .len = 3, .kind = .incomplete_sequence }, parseCsi("\x9b0;", 0));

    {
        const result = parseCsi("\x9bm", 0);
        try testing.expectEqual(@as(u8, 'm'), result.kind.csi.action);
        try testing.expectEqual(@as(u8, 0), result.kind.csi.count);
    }
    {
        const result = parseCsi("\x9b99m", 0);
        try testing.expectEqual(@as(u8, 'm'), result.kind.csi.action);
        try testing.expectEqual(@as(u8, 1), result.kind.csi.count);
        try testing.expectEqual(@as(u8, 99), result.kind.csi.attrs[0]);
    }
}
