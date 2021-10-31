const std = @import("std");

const termiolog = std.log.scoped(.termio);
const x11log = std.log.scoped(.x11);
const renderlog = std.log.scoped(.render);

const c = @cImport({
    @cInclude("xcb/xcb.h");
});

const xcommon = @import("xcommon.zig");
const CircularBuffer = @import("CircularBuffer.zig");
const Keyboard = @import("Keyboard.zig");

fn screenOfDisplay(conn: *c.xcb_connection_t, screen: c_int) ?*c.xcb_screen_t {
    var screen_it = screen;
    var it = c.xcb_setup_roots_iterator(c.xcb_get_setup(conn));
    while (it.rem != 0) : (screen_it -= 1) {
        if (screen_it == 0)
            return it.data;
        c.xcb_screen_next(&it);
    }
    return null;
}

fn enforceNoError(conn: *c.xcb_connection_t, cookie: c.xcb_void_cookie_t, context: []const u8) void {
    const optional_error = c.xcb_request_check(conn, cookie);
    if (optional_error) |err| {
        // TODO: the err has alot more fields, do we want to print them?
        x11log.err("{s} failed, error={}", .{context, err.*.error_code});
        std.os.exit(0xff);
    }
}

pub const Window = struct {
    conn: *c.xcb_connection_t,
    fd: c_int,
    window: c.xcb_drawable_t,

    background_color: u32,
    text_color: u32,

    gc: c.xcb_gcontext_t, // the "Graphics Context"

    font_height: u16,
    font_ascent: u16,

    cell_width: u16,
    cell_height: u16,
    pixel_width: u16,
    pixel_height: u16,

    keyboard: Keyboard = .{},

    pub fn init() Window {
        var default_screen_num: c_int = undefined;
        const conn = c.xcb_connect(null, &default_screen_num).?;
        errdefer c.xcb_disconnect(conn);
        {
            const err = c.xcb_connection_has_error(conn);
            if (err != 0) {
                x11log.err("xcb_conect failed, error={}", .{err});
                std.os.exit(0xff);
            }
        }
        x11log.info("xcb_connect returned {*}", .{conn});
        const screen = screenOfDisplay(conn, default_screen_num) orelse {
            x11log.err("failed to get screen {}", .{default_screen_num});
            std.os.exit(0xff);
        };
        x11log.info("default_screen={}", .{screen});

        const window_id = c.xcb_generate_id(conn);
        // TODO: can this fail?
        x11log.info("window_id={}", .{window_id});

//        const font_name = "fixed";
//        const font_id = c.xcb_generate_id(conn);
//        x11log.debug("loading font '{s}'...", .{font_name});
//        const font_cookie = c.xcb_open_font(conn, font_id, font_name.len, font_name);
//        {
//            const err = c.xcb_request_check(conn, font_cookie);
//            if (err != 0) {
//                std.log.err("xcb_open_font for '{s}' failed, error={}", .{font_name, error.error_code});
//                std.os.exit(0xff);
//            }
//        }

//        const font = c.XLoadQueryFont(display, font_name) orelse {
//            x11log.err("XLoadQueryFont for '{s}' failed (todo: get error info)", .{font_name});
//            std.os.exit(0xff);
//        };
//
        const font_width = 10; // hardcoded for now
//        const font_width = @intCast(c_uint, c.XTextWidth(font, "m", 1));
        const font_height = 16; // hardcoded for now
//        const font_height = @intCast(c_uint, font.*.ascent + font.*.descent);
//
//        const colormap = cfixed.DefaultColormap(display, screen);
//        x11log.info("colormap={}", .{colormap});
//
//        const black_pixel = x11AllocColor(display, colormap, "#000000");
//        x11log.info("black=0x{x}", .{black_pixel});
//        const gray_pixel = x11AllocColor(display, colormap, "#aaaaaa");
//        x11log.info("gray=0x{x}", .{gray_pixel});
//
        const x = 0;
        const y = 0;
        const cell_width = 80;
        const cell_height = 25;
        const border_width = 0;

        const pixel_width = cell_width * font_width;
        const pixel_height = cell_height * font_height;

        const window_options_mask =
              c.XCB_CW_BACK_PIXEL
            | c.XCB_CW_EVENT_MASK
            ;
        const window_options = [_]u32 {
            screen.black_pixel,
            c.XCB_EVENT_MASK_EXPOSURE | c.XCB_EVENT_MASK_KEY_PRESS| c.XCB_EVENT_MASK_KEY_RELEASE,
        };
//        var set_window_attrs: c.XSetWindowAttributes = undefined;
//        set_window_attrs.background_pixmap = c.ParentRelative;
//        set_window_attrs.event_mask = c.KeyPressMask | c.KeyReleaseMask | c.ExposureMask;
//        const set_window_attrs_mask = c.CWBackPixmap | c.CWEventMask;
//
        enforceNoError(conn, c.xcb_create_window_checked(
            conn,
            c.XCB_COPY_FROM_PARENT, // depth
            window_id,
            screen.root,
            x, y,
            pixel_width, pixel_height,
            border_width,
            c.XCB_WINDOW_CLASS_INPUT_OUTPUT,
            screen.root_visual,
            window_options_mask,
            &window_options,
        ), "xcb_create_window");

        // TODO: do I need to do an xcb_flush???

        const title = "zigterm";
        enforceNoError(conn, c.xcb_change_property_checked(
            conn,
            c.XCB_PROP_MODE_REPLACE,
            window_id,
            c.XCB_ATOM_WM_NAME,
            c.XCB_ATOM_STRING,
            8, // 8-bit characters
            title.len,
            title,
        ), "xcb_change_propery for window title");

        enforceNoError(conn, c.xcb_map_window_checked(conn, window_id), "xcb_map_window");

        const background_color = screen.black_pixel;
        const graphics_context_id = c.xcb_generate_id(conn);
        const gc_options_mask = 0
            | c.XCB_GC_BACKGROUND
            //| c.XCB_GC_FONT
            //| c.XCB_GC_GRAPHICS_EXPOSURE
            ;
        const gc_options = [_]u32 {
            background_color,
        };
        enforceNoError(
            conn,
            c.xcb_create_gc_checked(conn, graphics_context_id, screen.root, gc_options_mask, &gc_options),
            "xcb_create_gc",
        );
//
//        // TODO: what does this do?
//        _ = c.XSync(display, 0);
//        // TODO: check for error
//
        const fd = c.xcb_get_file_descriptor(conn);
        x11log.info("fd={}", .{fd});

        return .{
            .conn = conn,
            .fd = fd,
            .window = window_id,
            .background_color = background_color,
            .text_color = 0xff3399,
            //.foreground_pixel = gray_pixel,
            .gc = graphics_context_id,
            .font_height = @intCast(u16, font_height),
            //.font_ascent = font.*.ascent,
            .font_ascent = 10, // hardcoded for now
            .cell_width = cell_width,
            .cell_height = cell_height,
            .pixel_width = pixel_width,
            .pixel_height = pixel_height,
        };
    }

    pub fn drawString(self: Window, x: i16, y: i16, str: []const u8) void {
        if (str.len > 255) @panic("drawString: long strings not implemented");
        enforceNoError(self.conn, c.xcb_image_text_8_checked(
            self.conn,
            @intCast(u8, str.len),
            self.window,
            self.gc,
            x, y,
            str.ptr
        ), "xcb_image_text_8");
    }

    fn changeForeground(self: Window, color: u32) void {
        var values = [_]u32 { color };
        enforceNoError(
            self.conn,
            c.xcb_change_gc_checked(self.conn, self.gc, c.XCB_GC_FOREGROUND, &values),
            "xcb_change_gc for bg color",
        );
    }

    pub fn render(self: Window, buf: CircularBuffer) void {
//        renderlog.debug("render!", .{});

        self.changeForeground(self.background_color);
        const rectangle = c.xcb_rectangle_t {
            .x = 0, .y = 0, .width = self.pixel_width, .height = self.pixel_height,
        };
        enforceNoError(self.conn, c.xcb_poly_fill_rectangle(
            self.conn,
            self.window,
            self.gc,
            1,
            &rectangle,
        ), "xcb_poly_fill_rectangle");

        self.changeForeground(self.text_color);
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

        const err = c.xcb_flush(self.conn);
        if (err <= 0) {
            std.log.err("xcb_flush failed, returned {}", .{err});
            std.os.exit(0xff);
        }
    }

    pub fn onRead(self: *Window, term_fd_master: c_int, buf: CircularBuffer) void {
        _ = term_fd_master; _ = buf;

        var first_read = true;
        while (true) : (first_read = false) {
            const generic_event = c.xcb_poll_for_event(self.conn) orelse {
                if (first_read) {
                    // NOTE: I'm not sure if this is fullproof, what if we just got a
                    //       partial message? xcb doesn't seem to have a way to detect
                    //       when the connection is closed when using poll_for_event.
                    //       Maybe I could cal wait_for_event if we get here or on the
                    //       first pass when the handle is readable?
                    x11log.info("poll did not return a message even though fd is readable, we must be closed?", .{});
                    std.os.exit(0xff);
                }
                return;
            };
            //x11log.debug("got event {}", .{generic_event.*});
            defer std.c.free(generic_event);
            switch (generic_event.*.response_type & 0x7f) {
                c.XCB_EXPOSE => {
                    x11log.debug("x11event: expose!!!", .{});
                    self.render(buf);
                },
                c.XCB_KEY_PRESS => {
                    const event = @ptrCast(*c.xcb_key_press_event_t, generic_event);
                    x11log.debug("x11event: key press {}", .{event.detail});
                    const data = self.keyboard.keydown(@intToEnum(Keyboard.Keycode, event.detail));
                    if (data.len > 0) {
                        // TODO: instead of writing to the pseudoterm, keep it in a line buffer
                        //       so we can handle DELETE's TAB's etc before sending a complete
                        //       line to the pseudoterm
                        termiolog.debug("writing {} byte(s) to pseudoterm", .{data.len});
                        const len = std.os.write(term_fd_master, data.buf[0..data.len]) catch |err| {
                            std.log.err("write to pseudoterm failed with {}", .{err});
                            std.os.exit(0xff);
                        };
                        if (len != data.len) {
                            std.log.err("only wrote {} byte(s) out of {} to pseudoterm", .{len, data.len});
                            std.os.exit(0xff);
                        }
                    }
                },
                c.XCB_KEY_RELEASE => {
                    const event = @ptrCast(*c.xcb_key_release_event_t, generic_event);
                    x11log.debug("x11event: key release {}", .{event.detail});
                    self.keyboard.keyup(@intToEnum(Keyboard.Keycode, event.detail));
                },
                //c.XCB_MAP_NOTIFY => x11log.debug("x11event: map notify (ignore)", .{}),
                //c.XCB_CONFIGURE_NOTIFY => x11log.debug("x11event: configure notify (ignore)", .{}),
                //c.XCB_REPARENT_NOTIFY => x11log.debug("x11event: reparent notify (ignore)", .{}),
                //c.XCB_CLIENT_MESSAGE => {
                //    std.log.info("client message {}", .{generic_event.*});
                //},
                // This should be impossible because we only get events we registered for
                else => |t| std.debug.panic("x11event: unhandled {}", .{t}),
            }
        }
    }
};
