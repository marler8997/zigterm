const std = @import("std");

const Keyboard = @This();

// 24 - 33 q - p
// 38 - 46 a - l
// 52 - 58 z - m

pub const Keycode = enum(u8) {
    _1 = 10, _2 = 11, _3 = 12, _4 = 13, _5 = 14, _6 = 15, _7 = 16, _8 = 17, _9 = 18, _0 = 19, dash = 20, equal = 21, backspace = 22,
    // where is 23?
    q = 24, w = 25, e = 26, r = 27, t = 28, y = 29, u = 30, i = 31, o = 32, p = 33,
    //
    enter = 36,
    //
    a = 38, s = 39, d = 40, f = 41, g = 42, h = 43, j = 44, k = 45, l = 46,
    //
    lshift = 50,
    //
    z = 52, x = 53, c = 54, v = 55, b = 56, n = 57, m = 58,
    comma_and_left_angle_bracket = 59,
    period_and_right_angle_bracket = 60,
    slash_and_question_mark = 61,
    rshift = 62,
    //
    spacebar = 65,
    _,
};

// todo: we need to query the initial state of the keyboard when we startup
shift: bool = false,

pub const Data = struct {
    const max_len = 2;
    buf: [max_len]u8,
    len: std.math.IntFittingRange(0, max_len),
    pub const none = Data { .buf = undefined, .len = 0 };
    pub fn init(data: anytype) Data {
        var result: Data = undefined;
        @memcpy(&result.buf, &data, data.len);
        result.len = data.len;
        return result;
    }
};

fn keycodeToAscii(shift: bool, code: Keycode) u8 {
    if (shift) return switch (code) {
        ._1=>'!', ._2=>'@', ._3=>'#', ._4=>'$', ._5=>'%', ._6=>'^', ._7=>'&', ._8=>'*', ._9=>'(', ._0=>')',
        .dash=>'_', .equal=>'+',
        .backspace => unreachable,
        .q=>'Q', .w=>'W', .e=>'E', .r=>'R', .t=>'T', .y=>'Y', .u=>'U', .i=>'I', .o=>'O', .p=>'P',
        //
        .enter => unreachable,
        //
        .a=>'A', .s=>'S', .d=>'D', .f=>'F', .g=>'G', .h=>'H', .j=>'J', .k=>'K', .l=>'L',
        //
        .z=>'Z', .x=>'X', .v=> 'V', .c=>'C', .b=>'B', .n=>'N', .m=>'M',
        .comma_and_left_angle_bracket => '<',
        .period_and_right_angle_bracket => '>',
        .slash_and_question_mark => '?',
        .spacebar => ' ',
        else => unreachable,
    };
    return switch (code) {
        ._1=>'1', ._2=>'2', ._3=>'3', ._4=>'4', ._5=>'5', ._6=>'6', ._7=>'7', ._8=>'8', ._9=>'9', ._0=>'0',
        .dash=>'-', .equal=>'=',
        .backspace => unreachable,
        .q=>'q', .w=>'w', .e=>'e', .r=>'r', .t=>'t', .y=>'y', .u=>'u', .i=>'i', .o=>'o', .p=>'p',
        //
        .enter => unreachable,
        //
        .a=>'a', .s=>'s', .d=>'d', .f=>'f', .g=>'g', .h=>'h', .j=>'j', .k=>'k', .l=>'l',
        .z=>'z', .x=>'x', .v => 'v', .c=>'c', .b=>'b', .n=>'n', .m=>'m',
        .comma_and_left_angle_bracket => ',',
        .period_and_right_angle_bracket => '.',
        .slash_and_question_mark => '/',
        .spacebar => ' ',
        else => unreachable,
    };
}

pub fn keydown(self: *Keyboard, code: Keycode) Data {
    switch (code) {
        ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9, ._0, .dash, .equal =>
            return Data.init([_]u8 { keycodeToAscii(self.shift, code) }),
        .backspace => {
            std.log.warn("TODO: handle backspace", .{});
            return Data.none;
        },
        .q, .w, .e, .r, .t, .y, .u, .i, .o, .p =>
            return Data.init([_]u8 { keycodeToAscii(self.shift, code) }),
        .enter => return Data.init([_]u8 { '\r', '\n' }),
        .a, .s, .d, .f, .g, .h, .j, .k, .l =>
            return Data.init([_]u8 { keycodeToAscii(self.shift, code) }),
        .lshift => {
            self.shift = true;
            return Data.none;
        },
        .z, .x, .v, .c, .b, .n, .m,
        .comma_and_left_angle_bracket,
        .period_and_right_angle_bracket,
        .slash_and_question_mark,
            => return Data.init([_]u8 { keycodeToAscii(self.shift, code) }),
        .rshift => {
            self.shift = true;
            return Data.none;
        },
        .spacebar => 
            return Data.init([_]u8 { keycodeToAscii(self.shift, code) }),
        else => {
            std.log.warn("TODO: handle keydown {} (0x{0x})", .{code});
            return Data.none;
        },
    }
}

pub fn keyup(self: *Keyboard, code: Keycode) void {
    switch (code) {
        ._1, ._2, ._3, ._4, ._5, ._6, ._7, ._8, ._9, ._0, .dash, .equal, .backspace => {},
        .q, .w, .e, .r, .t, .y, .u, .i, .o, .p => {},
        .enter => {},
        .a, .s, .d, .f, .g, .h, .j, .k, .l => {},
        .lshift => self.shift = false,
        .z, .x, .v, .c, .b, .n, .m,
        .comma_and_left_angle_bracket,
        .period_and_right_angle_bracket,
        .slash_and_question_mark,
            => {},
        .rshift => self.shift = false,
        .spacebar => {},
        else => std.log.warn("TODO: handle keyup {} (0x{0x})", .{code}),
    }
}

