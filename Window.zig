const std = @import("std");
const Window = @This();

const termiolog = std.log.scoped(.termio);
const x11log = std.log.scoped(.x11);
const renderlog = std.log.scoped(.render);

const x = @import("x");
const Memfd = x.Memfd;
const CircularBuffer = x.CircularBuffer;

const xcommon = @import("xcommon.zig");
const Keyboard = @import("Keyboard.zig");

const bg_color = 0x333333;
const fg_color = 0xf7a41d;

fn getWindowId(base_id: u32) u32 { return base_id; }
fn getForegroundGcId(base_id: u32) u32 { return base_id + 1; }
fn getBackgroundGcId(base_id: u32) u32 { return base_id + 2; }

sock: std.os.socket_t,
recv_buf_memfd: Memfd,
recv_buf: CircularBuffer,
recv_buf_start: usize,

base_id: u32,

cell_width: u16,
cell_height: u16,

font_ascent: u8,
font_height: u8,

pixel_width: u16,
pixel_height: u16,

keyboard: Keyboard = .{},

// Need to initialize with a pointer because we have a pinned reference to ourselves
pub fn init() !Window {
    const display = x.getDisplay();

    const sock = x.connect(display) catch |err| {
        x11log.err("failed to connect to X server at '{s}': {s}", .{display, @errorName(err)});
        std.os.exit(0xff);
    };
    errdefer std.os.close(sock);
    x11log.debug("connected to '{s}'", .{display});

    {
        const len = comptime x.connect_setup.getLen(0, 0);
        var msg: [len]u8 = undefined;
        x.connect_setup.serialize(&msg, 11, 0, .{ .ptr = undefined, .len = 0 }, .{ .ptr = undefined, .len = 0 });
        send(sock, &msg);
    }

    const reader = std.io.Reader(std.os.socket_t, std.os.RecvFromError, readSocket) { .context = sock };
    const connect_setup_header = x.readConnectSetupHeader(reader, .{}) catch |err| {
        x11log.err("failed to read connect setup header: {}", .{err});
        std.os.exit(0xff);
    };
    switch (connect_setup_header.status) {
        .failed => {
            x11log.err("connect setup failed, version={}.{}, reason='{s}'", .{
                connect_setup_header.proto_major_ver,
                connect_setup_header.proto_minor_ver,
                connect_setup_header.readFailReason(reader),
            });
            std.os.exit(0xff);
        },
        .authenticate => {
            x11log.err("AUTHENTICATE! not implemented", .{});
            std.os.exit(0xff);
        },
        .success => {
            // TODO: check version?
            x11log.info("SUCCESS! version {}.{}", .{connect_setup_header.proto_major_ver, connect_setup_header.proto_minor_ver});
        },
        else => |status| {
            x11log.err("Error: expected 0, 1 or 2 as first byte of connect setup reply, but got {}", .{status});
            std.os.exit(0xff);
        }
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = &arena.allocator;

    const connect_setup = x.ConnectSetup {
        .buf = allocator.allocWithOptions(u8, connect_setup_header.getReplyLen(), 4, null) catch @panic("Out of memory"),
    };
    defer allocator.free(connect_setup.buf);
    readFull(reader, connect_setup.buf);

    const connect_setup_fixed = connect_setup.fixed();
    x11log.debug("{}", .{connect_setup_fixed});

    const format_list_offset = x.ConnectSetup.getFormatListOffset(connect_setup_fixed.vendor_len);
    const format_list_limit = x.ConnectSetup.getFormatListLimit(format_list_offset, connect_setup_fixed.format_count);
    var screen = connect_setup.getFirstScreenPtr(format_list_limit);

    const cell_width = 80;
    const cell_height = 25;

    const font_width = 8; // just hardcoded for now
    const font_height = 12; // just hardcoded for now

    const pixel_width = cell_width * font_width;
    const pixel_height = cell_height * font_height;

    const base_id = connect_setup.fixed().resource_id_base;
    const window_id = getWindowId(base_id);
    {
        var msg_buf: [x.create_window.max_len]u8 = undefined;
        const len = x.create_window.serialize(&msg_buf, .{
            .window_id = window_id,
            .parent_window_id = screen.root,
            .x = 0, .y = 0,
            .width = pixel_width, .height = pixel_height,
            .border_width = 0, // TODO: what is this?
            .class = .input_output,
            .visual_id = screen.root_visual,
        }, .{
//            .bg_pixmap = .copy_from_parent,
            .bg_pixel = bg_color,
//            //.border_pixmap =
//            .border_pixel = 0x01fa8ec9,
//            .bit_gravity = .north_west,
//            .win_gravity = .east,
//            .backing_store = .when_mapped,
//            .backing_planes = 0x1234,
//            .backing_pixel = 0xbbeeeeff,
//            .override_redirect = true,
//            .save_under = true,
            .event_mask = 0
                | x.create_window.event_mask.key_press
                | x.create_window.event_mask.key_release
                //| x.create_window.event_mask.button_press
                //| x.create_window.event_mask.button_release
                //| x.create_window.event_mask.enter_window
                //| x.create_window.event_mask.leave_window
                //| x.create_window.event_mask.pointer_motion
                //| x.create_window.event_mask.keymap_state
                | x.create_window.event_mask.exposure
                ,
        });
        send(sock, msg_buf[0..len]);
    }

    // TODO: send ChangeProperty to change the title
    //     mode=Replace(0x00) window=$window_id property=0x27("WM_NAME") type=0x1f("STRING") data='THE_TITLE'

    {
        var msg: [x.map_window.len]u8 = undefined;
        x.map_window.serialize(&msg, window_id);
        send(sock, &msg);
    }

    createGc(sock, getBackgroundGcId(base_id), screen.root, bg_color, bg_color);
    createGc(sock, getForegroundGcId(base_id), screen.root, fg_color, bg_color);

    const memfd = try Memfd.init("zigtermCircularBuffer");

    return Window{
        .sock = sock,
        .recv_buf_memfd = memfd,
        .recv_buf = CircularBuffer.initMinSize(memfd, 4096) catch |err| {
            x11log.err("failed to create circular buffer: {s}", .{@errorName(err)});
            std.os.exit(0xff);
        },
        .recv_buf_start = 0,
        .base_id = base_id,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .font_ascent = 4,
        .font_height = font_height,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
    };
}

fn createGc(sock: std.os.socket_t, gc_id: u32, root_id: u32, fg: u32, bg: u32) void {
    var msg_buf: [x.create_gc.max_len]u8 = undefined;
    const len = x.create_gc.serialize(&msg_buf, .{
        .gc_id = gc_id,
        .drawable_id = root_id,
    }, .{
        .background = bg,
        .foreground = fg,
    });
    send(sock, msg_buf[0..len]);
}

pub fn drawString(self: Window, x_coord: i16, y: i16, str: []const u8) void {
    if (str.len > 255) @panic("drawString: long strings not implemented");
    const str_len = @intCast(u8, str.len);

    var msg_buf: [x.image_text8.max_len]u8 = undefined;
    x.image_text8.serialize(&msg_buf, .{
        .drawable_id = getWindowId(self.base_id),
        .gc_id = getForegroundGcId(self.base_id),
        .x = x_coord, .y = y,
        .text = .{ .ptr = str.ptr, .len = str_len },
    });
    send(self.sock, msg_buf[0 .. x.image_text8.getLen(str_len)]);
}

pub fn render(self: Window, buf: CircularBuffer) void {
//        renderlog.debug("render!", .{});

    {
        var msg: [x.poly_fill_rectangle.getLen(1)]u8 = undefined;
        x.poly_fill_rectangle.serialize(&msg, .{
            .drawable_id = getWindowId(self.base_id),
            .gc_id = getBackgroundGcId(self.base_id),
        }, &[_]x.Rectangle {
            .{ .x = 0, .y = 0, .width = self.pixel_width, .height = self.pixel_height },
        });
        send(self.sock, &msg);
    }

    {
        var start = buf.ptr;
        var cursor = blk: {
            if (buf.cursor < buf.size)
                break :blk start + buf.cursor;
            start += buf.cursor;
            break :blk start + buf.size;
        };

        var y_cell = self.cell_height;
        while (true) {
            if (y_cell == 0) {
                // done drawing to the view
                break;
            }
            y_cell -= 1;
            const y = self.font_ascent + (self.font_height * y_cell);
            if (xcommon.toNewline(start, cursor)) |newline| {
                const line_start = newline + 1;
                const line_len = @ptrToInt(cursor) - @ptrToInt(line_start);
                self.drawString(0, @intCast(i16, y), line_start[0 .. line_len]);
                cursor = newline - 1;
            } else {
                const line_len = @ptrToInt(cursor) - @ptrToInt(start);
                self.drawString(0, @intCast(i16, y), start[0 .. line_len]);
                break;
            }
        }
    }
}

pub fn onRead(self: *Window, term_fd_master: c_int, term_buf: CircularBuffer) void {
    _ = term_buf;
    {
        const len = std.os.recv(self.sock, self.recv_buf.next(), 0) catch |err| {
            x11log.err("recv on x11 socket failed with {s}", .{@errorName(err)});
            std.os.exit(0xff);
        };
        if (len == 0) {
            x11log.info("X server connection closed", .{});
            std.os.exit(0);
        }
        self.recv_buf.scroll(len);
        x11log.debug("got {} bytes", .{len});
    }
    while (true) {
        while (self.recv_buf_start > self.recv_buf.cursor) {
            self.recv_buf_start -= self.recv_buf.size;
        }
        const recv_data = self.recv_buf.ptr[self.recv_buf_start .. self.recv_buf.cursor];
        const parsed = x.parseMsg(@alignCast(4, recv_data));
        if (parsed.len == 0)
            break;
        self.recv_buf_start += parsed.len;
        const msg = parsed.msg;
        switch (msg.kind) {
            .key_press => {
                const event = @ptrCast(*x.Event.KeyOrButton, msg);
                x11log.debug("key_press: {}", .{event.detail});
                const data = self.keyboard.keydown(@intToEnum(Keyboard.Keycode, event.detail));
                if (data.len > 0) {
                    // TODO: instead of writing to the pseudoterm, keep it in a line buffer
                    //       so we can handle DELETE's TAB's etc before sending a complete
                    //       line to the pseudoterm
                    termiolog.debug("writing {} byte(s) to pseudoterm", .{data.len});
                    const len = std.os.write(term_fd_master, data.buf[0..data.len]) catch |err| {
                        x11log.err("write to pseudoterm failed with {}", .{err});
                        std.os.exit(0xff);
                    };
                    if (len != data.len) {
                        x11log.err("only wrote {} byte(s) out of {} to pseudoterm", .{len, data.len});
                        std.os.exit(0xff);
                    }
                }
            },
            .key_release => {
                const event = @ptrCast(*x.Event.KeyOrButton, msg);
                x11log.debug("key_release {}", .{event.detail});
                self.keyboard.keyup(@intToEnum(Keyboard.Keycode, event.detail));
            },
            .expose => {
                const event = @ptrCast(*x.Event.Expose, msg);
                x11log.info("expose: {}", .{event});
                // TODO: call render?
            },
            else => {
                x11log.err("unhandled x11 message {}", .{msg.kind});
                std.os.exit(0xff);
            },
        }

    }
}

fn send(sock: std.os.socket_t, data: []const u8) void {
    const sent = std.os.send(sock, data, 0) catch |err| {
        x11log.err("send {} bytes failed with {s}", .{data.len, @errorName(err)});
        std.os.exit(0xff);
    };
    if (sent != data.len) {
        x11log.err("send {} only sent {}\n", .{data.len, sent});
        std.os.exit(0xff);
    }
}

fn readSocket(sock: std.os.socket_t, buf: []u8) !usize {
    return std.os.recv(sock, buf, 0);
}

fn readFull(reader: anytype, buf: []u8) void {
    x.readFull(reader, buf) catch |err| {
        x11log.err("failed to read {} bytes from X server: {s}", .{buf.len, @errorName(err)});
        std.os.exit(0xff);
    };
}
