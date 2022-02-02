const std = @import("std");
const CircularBuffer = @import("CircularBuffer.zig");
const escapes = @import("escapes.zig");

const LineLayout = @This();

width: u16,
height: u16,

// an array of rows, length is same as 'height'
rows: [*]RowDrawings,
// an array of commands, each row is allocated 'width' number of commands
commands: [*]DrawCommand,
// an array of characters used by row commands, each row is allocatd 'width number of commands
draw_char_data: [*]u8,

pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) error{OutOfMemory}!LineLayout {
    const cell_count = @intCast(u32, width) * @intCast(u32, height);
    const draw_char_data = try allocator.alloc(u8, cell_count);
    const commands = try allocator.alloc(DrawCommand, cell_count);
    const rows = try allocator.alloc(RowDrawings, height);
    for (rows) |*row, i| {
        row.* = RowDrawings{
            .commands_len = 0,
            .commands = commands.ptr + (@intCast(usize, width) * i),
            .char_data = draw_char_data.ptr + (@intCast(usize, width) * i),
        };
    }

    return LineLayout{
        .width = width,
        .height = height,
        .rows = rows.ptr,
        .commands = commands.ptr,
        .draw_char_data = draw_char_data.ptr,
    };
}

const RowDrawings = struct {
    commands_len: u16,
    commands: [*]DrawCommand, // up to 'width' commands
    char_data: [*]u8, // a 'width' lengh

    pub fn commandSlice(self: RowDrawings) []DrawCommand {
        return self.commands[0 .. self.commands_len];
    }
};

const DrawCommand = union(enum) {
    text: struct {
        char_data_offset: u16,
        char_data_limit: u16,
        //text_attributes: enum {
        //    default_color,
        //    green,
        //},
    },
};

pub const LayoutContext = struct {
    previous_row_index: u16,
};

pub fn initLayout(self: LineLayout) LayoutContext {
    return LayoutContext{ .previous_row_index = self.height };
}

const RowDrawBuilder = struct {
    width: u16,
    rows: [*]RowDrawings,
    row_index: u16,
    state: enum {
        initial, // emitting characters to
    } = .initial,
    row_drawing_cmd_index: u16,
    row_drawing_char_data_start: u16,
    row_drawing_char_data_index: u16,

    pub fn finish(self: *RowDrawBuilder) void {
        switch (self.state) {
            .initial => {
                self.rows[self.row_index].commands[self.row_drawing_cmd_index] = DrawCommand{
                    .text = .{
                        .char_data_offset = self.row_drawing_char_data_start,
                        .char_data_limit = self.row_drawing_char_data_index,
                    },
                };
                self.rows[self.row_index].commands_len = self.row_drawing_cmd_index + 1;
            },
        }

    }

    pub fn emitChar(self: *RowDrawBuilder, c: u8) void {
        switch (self.state) {
            .initial => {
                if (self.row_drawing_char_data_index < self.width) {
                    self.rows[self.row_index].char_data[self.row_drawing_char_data_index] = c;
                }
                self.row_drawing_char_data_index += 1;
            },
        }
    }
    pub fn backspace(self: *RowDrawBuilder) void {
        switch (self.state) {
            .initial => {
                if (self.row_drawing_char_data_index == 0) {
                    std.log.warn("got backspace at beginning of line?", .{});
                } else {
                    self.row_drawing_char_data_index -= 1;
                }
            },
        }
    }
};

/// TODO: takes a line and turns it into drawing commands
fn layoutLine(self: LineLayout, context: *LayoutContext, line: []const u8) void {
    std.debug.assert(context.previous_row_index != 0);
    context.previous_row_index -= 1;

    var builder = RowDrawBuilder {
        .width = self.width,
        .rows = self.rows,
        .row_index = context.previous_row_index,
        .state = .initial,
        .row_drawing_cmd_index = 0,
        .row_drawing_char_data_start = 0,
        .row_drawing_char_data_index = 0,
    };

    var line_index: usize = 0;
    while (line_index < line.len) {

        const escape = escapes.parseEscape(line[line_index..]);
        switch (escape.kind) {
            .none => builder.emitChar(line[line_index]),
            .backspace => builder.backspace(),
            .incomplete_sequence => {
                std.debug.assert(line_index + escape.len == line.len);
                // don't emit anything to builder???
            },
            .ignore_for_now => {},
            .unimplemented_sequence => {
                // just ignore for now?
            },
            .csi => |csi| {
                switch (csi.action) {
                    'm' => {
                        for (csi.attrSlice()) |attr| {
                            switch (attr) {
                                1 => std.log.info("TODO: set BOLD", .{}),
                                32 => std.log.info("TODO: set green foreground", .{}),
                                else => std.log.info("TODO: set attr {}", .{attr}),
                            }
                        }
                    },
                    else => |action| {
                        std.log.info("TODO: handle csi action {}", .{action});
                    },
                }
            },
        }
        line_index += escape.len;
    }

    builder.finish();
}

pub fn layoutBuffer(self: LineLayout, buf: CircularBuffer) void {
    var start = buf.ptr;
    var cursor = blk: {
        if (buf.cursor < buf.size)
            break :blk start + buf.cursor;
        start += buf.cursor;
        break :blk start + buf.size;
    };

    var context = self.initLayout();
    while (context.previous_row_index != 0) {
        if (toNewline(start, cursor)) |newline| {
            const line_start = newline + 1;
            const line_len = @ptrToInt(cursor) - @ptrToInt(line_start);
            self.layoutLine(&context, line_start[0 .. line_len]);
            cursor = newline - 1;
        } else {
            const line_len = @ptrToInt(cursor) - @ptrToInt(start);
            self.layoutLine(&context, start[0 .. line_len]);
            break;
        }
    }
}

fn toNewline(start: [*]u8, cursor_arg: [*]u8) ?[*]u8 {
    var cursor = cursor_arg;
    while (true) {
        if (@ptrToInt(cursor) <= @ptrToInt(start))
            return null;
        cursor -= 1;
        if (cursor[0] == '\n')
            return cursor;
    }
}
