const std = @import("std");
const Window = @This();

const termiolog = std.log.scoped(.termio);
const x11log = std.log.scoped(.x11);
const renderlog = std.log.scoped(.render);

const x = @import("x");
const Memfd = x.Memfd;
const ContiguousReadBuffer = x.ContiguousReadBuffer;
const CircularBuffer = @import("CircularBuffer.zig");
const LineLayout = @import("LineLayout.zig");

const shell = @import("shell.zig");
const Keyboard = @import("Keyboard.zig");

const bg_color = 0x333333;
const fg_color = 0xf7a41d;

fn getWindowId(base_id: u32) u32 { return base_id; }
fn getForegroundGcId(base_id: u32) u32 { return base_id + 1; }
fn getBackgroundGcId(base_id: u32) u32 { return base_id + 2; }

sock: std.os.socket_t,
recv_buf_memfd: Memfd,
recv_buf: ContiguousReadBuffer,

base_id: u32,

layout: LineLayout,

font_dims: FontDims,

pixel_width: u16,
pixel_height: u16,

keyboard: Keyboard = .{},

// Need to initialize with a pointer because we have a pinned reference to ourselves
pub fn init(layout: LineLayout) !Window {
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

    const base_id = connect_setup.fixed().resource_id_base;
    createGc(sock, getBackgroundGcId(base_id), screen.root, bg_color, bg_color);
    createGc(sock, getForegroundGcId(base_id), screen.root, fg_color, bg_color);

    //
    // Right now instead of getting the entire fontinfo structure, we just check
    // the size of a single character.  If it's a fixed width font, this might
    // be good enough.
    //
    {
        const text_literal = [_]u16 { 'm' };
        const text = x.Slice(u16, [*]const u16) { .ptr = &text_literal, .len = text_literal.len };
        var msg: [x.query_text_extents.getLen(text.len)]u8 = undefined;
        x.query_text_extents.serialize(&msg, getForegroundGcId(base_id), text);
        send(sock, &msg);
    }

    const font_dims = blk: {
        var buf align(4) = [_]u8 { undefined } ** @sizeOf(x.ServerMsg.QueryTextExtents);
        const msg_len = try x.readOneMsg(reader, &buf);
        switch (x.serverMsgTaggedUnion(&buf)) {
            .reply => |msg_reply| {
                if (msg_len != @sizeOf(x.ServerMsg.QueryTextExtents)) {
                    std.log.err("unexpected reply {}", .{msg_reply});
                    std.os.exit(0xff);
                }
                const msg = @ptrCast(*x.ServerMsg.QueryTextExtents, msg_reply);
                break :blk FontDims{
                    .width = @intCast(u8, msg.overall_width),
                    .height = @intCast(u8, msg.font_ascent + msg.font_descent),
                    .left = @intCast(i16, msg.overall_left),
                    .ascent = msg.font_ascent,
                };
            },
            else => |msg| {
                std.log.err("expected a reply but got {}", .{msg});
                std.os.exit(0xff);
            },
        }
    };

    const pixel_width = layout.width * font_dims.width;
    const pixel_height = layout.height * font_dims.height;

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

    const memfd = try Memfd.init("zigtermX11ReadBuffer");
    const recv_buf_capacity = std.mem.alignForward(4096, std.mem.page_size);

    return Window{
        .sock = sock,
        .recv_buf_memfd = memfd,
        .recv_buf = ContiguousReadBuffer{
            .half_size = recv_buf_capacity,
            .double_buffer_ptr = memfd.toDoubleBuffer(recv_buf_capacity) catch |err| {
                x11log.err("failed to create circular buffer: {s}", .{@errorName(err)});
                std.os.exit(0xff);
            },
        },
        .base_id = base_id,
        .layout = layout,
        .font_dims = font_dims,
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

pub fn clearRect(self: Window, area: x.Rectangle) void {
    var msg: [x.clear_area.len]u8 = undefined;
    x.clear_area.serialize(&msg, false, getWindowId(self.base_id), area);
    send(self.sock, &msg);
}

pub fn render(self: Window, term_buf: CircularBuffer) void {
    self.layout.layoutBuffer(term_buf);
    {
        var row: u16 = 0;
        while (row < self.layout.height) : (row += 1) {
            const y = self.font_dims.ascent + (self.font_dims.height * @intCast(i16, row));

            const row_drawings = self.layout.rows[row];
            var content_len: u16 = 0;
            for (row_drawings.commandSlice()) |cmd| {
                switch (cmd) {
                    .text => |text| {
                        const str = row_drawings.char_data[text.char_data_offset..text.char_data_limit];
                        self.drawString(0, @intCast(i16, y), str);
                        content_len += @intCast(u16, str.len);
                    },
                }
            }
            if (content_len < self.layout.width) {
                const chars_left = self.layout.width - content_len;
                self.clearRect(.{
                    .x = @intCast(i16, (content_len * self.font_dims.width)) - self.font_dims.left,
                    .y = y - self.font_dims.ascent,
                    .width = chars_left * self.font_dims.width,
                    .height = self.font_dims.height,
                });
            }
        }
    }
}

pub fn onRead(self: *Window, term_fd_master: c_int, term_buf: CircularBuffer) void {
    {
        const recv_buf = self.recv_buf.nextReadBuffer();
        if (recv_buf.len == 0) {
            x11log.err("x11 circular buffer capacity {} is too small!", .{self.recv_buf.half_size});
            std.os.exit(0xff);
        }
        const len = std.os.recv(self.sock, recv_buf, 0) catch |err| {
            x11log.err("recv on x11 socket failed with {s}", .{@errorName(err)});
            std.os.exit(0xff);
        };
        if (len == 0) {
            x11log.info("X server connection closed", .{});
            std.os.exit(0);
        }
        self.recv_buf.reserve(len);
        x11log.debug("got {} bytes", .{len});
    }
    while (true) {
        const recv_data = self.recv_buf.nextReservedBuffer();
        const msg_len = x.parseMsgLen(@alignCast(4, recv_data));
        if (msg_len == 0)
            break;
        self.recv_buf.release(msg_len);
        //self.recv_buf.resetIfEmpty(); // this might help cache locality and therefore performance
        // TODO: I need to verify the message internals don't go past the
        //       end of the buffer
        switch (x.serverMsgTaggedUnion(@alignCast(4, recv_data.ptr))) {
            .key_press => |msg| {
                x11log.debug("key_press: {}", .{msg.detail});
                const data = self.keyboard.keydown(@intToEnum(Keyboard.Keycode, msg.detail));
                if (data.len > 0) {
                    // TODO: instead of writing to the pseudoterm, keep it in a line buffer
                    //       so we can handle DELETE's TAB's etc before sending a complete
                    //       line to the pseudoterm
                    termiolog.debug("writing {} byte(s) to pseudoterm", .{data.len});
                    shell.write(term_fd_master, data.buf[0..data.len]);
                }
            },
            .key_release => |msg| {
                x11log.debug("key_release {}", .{msg.detail});
                self.keyboard.keyup(@intToEnum(Keyboard.Keycode, msg.detail));
            },
            .expose => |msg| {
                x11log.info("expose: {}", .{msg});
                const new_cell_width = @divTrunc(msg.width, self.font_dims.width);
                const new_cell_height = @divTrunc(msg.height, self.font_dims.height);
                if (new_cell_width != self.layout.width or new_cell_height != self.layout.height) {
                    std.log.info("TODO: resize {}x{} to {}x{}", .{
                        self.layout.width,
                        self.layout.height,
                        new_cell_width,
                        new_cell_height,
                    });
                }
                self.render(term_buf);
            },
            else => {
                const msg = @ptrCast(*x.ServerMsg.Generic, recv_data.ptr);
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

const FontDims = struct {
    width: u8,
    height: u8,
    left: i16, // pixels to the left of the text basepoint
    ascent: i16, // pixels up from the text basepoint to the top of the text
};
