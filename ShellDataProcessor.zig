const std = @import("std");
const testing = std.testing;

const Memfd = @import("x").Memfd;
const CircularBuffer = @import("CircularBuffer.zig");

const ShellDataProcessor = @This();

rewind: usize = 0,
restore: WriteOffsets = .{},

// the amount we'll need to rewind the buffer on new data so we can
// access the carriage_return target
//cr_target_rewind: usize,
//restore_write_pos_at_cr: usize,
pub fn init() ShellDataProcessor {
    return .{};
}

pub fn processNewData(self: *ShellDataProcessor, buf: *CircularBuffer, new_data_len: usize) void {
    // we rewind the buffer because processing the data can actually remove data (i.e. carriage return)
    const rewind = self.rewind;

    std.log.info("cursor={}, got {} bytes of new data, rewind is {}", .{buf.cursor, new_data_len, rewind});
    const process_buf = (buf.ptr + buf.cursor - rewind)[0 .. rewind + new_data_len];
    const processed_len = self.processBuf(process_buf);

    if (processed_len >= rewind) {
        _ = buf.scroll(processed_len - rewind);
    } else {
        _ = buf.rewind(rewind - processed_len);
    }
    std.log.info("after process, process_len={}, cursor={}", .{processed_len, buf.cursor});
}


const WriteOffsets = struct {
    write: usize = 0,
    max_write_before_rewind: usize = 0,
};

//
// TODO: this logic is extremely complex and needs a buttload of testing
//
fn processBuf(self: *ShellDataProcessor, buf: []u8) usize {
    //std.log.info("process {}, rewind={} write={} max_write_before_rewind={}", .{
    //    buf.len,
    //    self.rewind,
    //    self.restore.write,
    //    self.restore.max_write_before_rewind,
    //});

    var read = self.rewind;
    var line_start: usize = 0;
    var offsets = WriteOffsets {
        .write = self.restore.write,
        .max_write_before_rewind = self.restore.max_write_before_rewind
    };

    while (read < buf.len) {
        const escape = @import("escapes.zig").parseEscape(buf[read..]);
        switch (escape.kind) {
            .incomplete_sequence => @panic("not impl"),
            .ignore_for_now => @panic("not impl"),
            .unimplemented_sequence => @panic("not impl"),
            .backspace => {
                if (offsets.write == line_start) {
                    std.log.warn("got backspace at line start?", .{});
                } else {
                    offsets.write -= 1;
                }
            },
            .csi => |csi| switch (csi.action) {
                'D' => {
                    //if (csi.count != 1)
                    //    std.debug.panic("got 'D' escape with {} args", .{csi.count});
                    //const diff = offsets.write - line_start;
                    @panic("not impl");
                },
                'm' => memcpy(u8, buf.ptr + offsets.write, buf[read .. read + escape.len]),
                else => std.debug.panic("csi action '{}' not implemented", .{csi.action}),
            },
            .none => switch (buf[read]) {
                '\r' => {
                    offsets.max_write_before_rewind = offsets.write;
                    offsets.write = line_start;
                    //std.log.info("at cr: read={} line_start={} {}", .{read, line_start, offsets});
                },
                '\n' => {
                    offsets.write = std.math.max(offsets.write, offsets.max_write_before_rewind);
                    buf[offsets.write] = '\n';
                    offsets.write += 1;
                    line_start = offsets.write;
                    //std.log.info("at nl: read={} line_start={} {}", .{read, line_start, offsets});
                },
                else => {
                    buf[offsets.write] = buf[read];
                    offsets.write += 1;
                },
            },
        }
        read += escape.len;
    }

    std.log.info("!!! offsets {}", .{offsets});
    if (offsets.write >= offsets.max_write_before_rewind) {
        self.rewind = offsets.write - line_start;
        self.restore = .{
            .write = self.rewind,
            .max_write_before_rewind = 0,
        };
        return offsets.write;
    } else {
        self.rewind = offsets.max_write_before_rewind - line_start;
        self.restore = .{
            .write = offsets.write - line_start,
            .max_write_before_rewind = offsets.max_write_before_rewind - line_start,
        };
        return offsets.max_write_before_rewind;
    }
}

pub fn memcpy(comptime T: type, dest: [*]T, source: []const T) void {
    for (source) |s, i|
        dest[i] = s;
}



const TestData = struct {
    input: []const u8,
    output: []const u8,
};
fn runTest(buf: *CircularBuffer, data: []const TestData) !void {
    buf.cursor = 0; // reset the buffer
    var processor = ShellDataProcessor { };

    // TODO: test that going 1 byte at a time also yields the same result
    for (data) |d| {
        const read_buf = buf.next();
        @memcpy(read_buf.ptr, d.input.ptr, d.input.len);
        processor.processNewData(buf, d.input.len);
        try testing.expect(std.mem.eql(u8, d.output, buf.ptr[0 .. buf.cursor]));
    }
}

test {
    const buf_memfd = try Memfd.init("zigtermCircularBuffer");
    defer buf_memfd.deinit();

    const buf_size = std.mem.alignForward(std.mem.page_size, 4096);
    var buf = try CircularBuffer.init(buf_memfd, buf_size);

    try runTest(&buf, &[_]TestData{
        .{ .input = "abc", .output = "abc" },
        .{ .input = "def", .output = "abcdef" },
    });
    try runTest(&buf, &[_]TestData{
        .{ .input = "abcd\r", .output = "abcd" },
        .{ .input = "efg", .output = "efgd" },
    });
    try runTest(&buf, &[_]TestData{
        .{ .input = "abc\r\n", .output = "abc\n" },
        .{ .input = "efg", .output = "abc\nefg" },
    });
}
