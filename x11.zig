const std = @import("std");

const termiolog = std.log.scoped(.termio);
const x11log = std.log.scoped(.x11);
const renderlog = std.log.scoped(.render);

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
});

const xcommon = @import("xcommon.zig");
const CircularBuffer = @import("CircularBuffer.zig");

// Stuff that doesn't work in zig translate C yet
const cfixed = struct {
    pub inline fn DefaultScreen(dpy: anytype) c_int {
        return std.zig.c_translation.cast(c._XPrivDisplay, dpy).*.default_screen;
    }
    pub inline fn ScreenOfDisplay(dpy: anytype, scr: c_int) ?*c.Screen {
        return &std.zig.c_translation.cast(c._XPrivDisplay, dpy).*.screens[@intCast(usize, scr)];
    }
    pub inline fn RootWindow(dpy: anytype, scr: anytype) c.Window {
        return ScreenOfDisplay(dpy, scr).?.*.root;
    }
    pub inline fn ConnectionNumber(dpy: anytype) c_int {
        return @import("std").zig.c_translation.cast(c._XPrivDisplay, dpy).*.fd;
    }
    pub inline fn DefaultColormap(dpy: anytype, scr: anytype) c.Colormap {
        return ScreenOfDisplay(dpy, scr).?.*.cmap;
    }
    pub inline fn DefaultDepth(dpy: anytype, scr: anytype) c_int {
        return ScreenOfDisplay(dpy, scr).?.*.root_depth;
    }
    pub inline fn DefaultVisual(dpy: anytype, scr: anytype) *c.Visual {
        return ScreenOfDisplay(dpy, scr).?.*.root_visual;
    }
};

pub const Window = struct {
    display: *c.Display,
    fd: c_int,
    window: c.Window,

    background_pixel: c_ulong,
    foreground_pixel: c_ulong,

    gc: c.GC, // the "Graphics Context"

    font_height: u16,
    font_ascent: c_int,

    cell_width: u16,
    cell_height: u16,
    pixel_width: c_uint,
    pixel_height: c_uint,

    pub fn init() Window {
        const display = c.XOpenDisplay(null) orelse {
            x11log.err("XOpenDisplay failed (todo: get error info)", .{});
            std.os.exit(0xff);
        };
        x11log.info("XOpenDisplay returned {*}", .{display});
        const screen = cfixed.DefaultScreen(display);
        x11log.info("default_screen={}", .{screen});
        const root_window = cfixed.RootWindow(display, screen);
        x11log.info("root_window={}", .{root_window});

        const fd = cfixed.ConnectionNumber(display);
        x11log.info("fd={}", .{fd});

        const font_name = "fixed";
        x11log.debug("loading font '{s}'...", .{font_name});
        const font = c.XLoadQueryFont(display, font_name) orelse {
            x11log.err("XLoadQueryFont for '{s}' failed (todo: get error info)", .{font_name});
            std.os.exit(0xff);
        };

        const font_width = @intCast(c_uint, c.XTextWidth(font, "m", 1));
        const font_height = @intCast(c_uint, font.*.ascent + font.*.descent);

        const colormap = cfixed.DefaultColormap(display, screen);
        x11log.info("colormap={}", .{colormap});

        const black_pixel = x11AllocColor(display, colormap, "#000000");
        x11log.info("black=0x{x}", .{black_pixel});
        const gray_pixel = x11AllocColor(display, colormap, "#aaaaaa");
        x11log.info("gray=0x{x}", .{gray_pixel});

        const x = 0;
        const y = 0;
        const cell_width = 80;
        const cell_height = 25;
        const border_width = 0;

        const pixel_width = cell_width * font_width;
        const pixel_height = cell_height * font_height;

        var set_window_attrs: c.XSetWindowAttributes = undefined;
        set_window_attrs.background_pixmap = c.ParentRelative;
        set_window_attrs.event_mask = c.KeyPressMask | c.KeyReleaseMask | c.ExposureMask;
        const set_window_attrs_mask = c.CWBackPixmap | c.CWEventMask;

        const window = c.XCreateWindow(
            display,
            root_window,
            x, y,
            pixel_width, pixel_height,
            border_width,
            cfixed.DefaultDepth(display, screen),
            c.InputOutput, // TODO: is this right?
            cfixed.DefaultVisual(display, screen),
            set_window_attrs_mask,
            &set_window_attrs,
        );
        // TODO: how to check for an error?

        // TODO: this should be a command-line option
        _ = c.XStoreName(display, window, "zigterm"); // sets the window title
        // TODO: check for error


        // TODO: not sure what this does
        _ = c.XMapWindow(display, window);
        // TODO: check for error

        const graphics_context = c.XCreateGC(display, window, 0, null) orelse {
            x11log.err("XCreateGC failed (todo: get error info)", .{});
            std.os.exit(0xff);
        };
        // TODO: check for error

        // TODO: what does this do?
        _ = c.XSync(display, 0);
        // TODO: check for error

        return .{
            .display = display,
            .fd = fd,
            .window = window,
            .background_pixel = black_pixel,
            .foreground_pixel = gray_pixel,
            .gc = graphics_context,
            .font_height = @intCast(u16, font_height),
            .font_ascent = font.*.ascent,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .pixel_width = pixel_width,
            .pixel_height = pixel_height,
        };
    }

    pub fn drawString(self: Window, x: c_int, y: c_int, str: []const u8) void {
        _ = c.XDrawString(self.display, self.window, self.gc, x, y, str.ptr, @intCast(c_int, str.len));
        // TODO: handle error
    }


    pub fn render(self: Window, buf: CircularBuffer) void {
        renderlog.debug("render!", .{});
        _ = c.XSetForeground(self.display, self.gc, self.background_pixel);
        // TODO: check for error

        _ = c.XFillRectangle(
            self.display,
            self.window,
            self.gc,
            0, 0,
            self.pixel_width,
            self.pixel_height,
        );
        // TODO: check for error

        _ = c.XSetForeground(self.display, self.gc, self.foreground_pixel);
        // TODO: check for error

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
                    self.drawString(0, y, line_start[0 .. line_len]);
                    cursor = newline - 1;
                } else {
                    const line_len = @ptrToInt(cursor) - @ptrToInt(start);
                    self.drawString(0, y, start[0 .. line_len]);
                    break;
                }
            }
        }

        _ = c.XSync(self.display, 0);
        // TODO: check for error
    }

    pub fn onRead(self: Window, term_fd_master: c_int, buf: CircularBuffer) void {
        while (c.XPending(self.display) != 0) {
            var generic_event: c.XEvent = undefined;

            _ = c.XNextEvent(self.display, &generic_event);
            // TODO: handle return value?

            switch (generic_event.type) {
                c.Expose => {
                    self.render(buf);
                },
                c.KeyPress => {
                    const event = &generic_event.xkey;
                    var str_buf: [32]u8 = undefined;
                    var key_sym: c.KeySym = undefined;
                    const num = c.XLookupString(event, &str_buf, str_buf.len, &key_sym, 0);
                    // TODO: instead of writing to the pseudoterm, keep it in a line buffer
                    //       so we can handle DELETE's TAB's etc before sending a complete
                    //       line to the pseudoterm
                    termiolog.debug("writing {} byte(s) to pseudoterm", .{num});
                    const len = std.os.write(term_fd_master, str_buf[0..@intCast(usize, num)]) catch |err| {
                        std.log.err("write to pseudoterm failed with {}", .{err});
                        std.os.exit(0xff);
                    };
                    if (len != num) {
                        std.log.err("only wrote {} byte(s) out of {} to pseudoterm", .{len, num});
                        std.os.exit(0xff);
                    }
                },
                c.KeyRelease => {
                    // do nothing for now
                },
                // This should be impossible because we only get events we registered for
                else => |t| std.debug.panic("unhandled x11 event {}", .{t}),
            }
        }
    }

};

fn x11AllocColor(display: *c.Display, colormap: c.Colormap, color_name: [*:0]const u8) c_ulong {
    var color: c.XColor = undefined;
    if (0 == c.XAllocNamedColor(display, colormap, color_name, &color, &color)) {
        x11log.err("XAllocNamedColor for '{s}' failed (todo: get error info)", .{color_name});
        std.os.exit(0xff);
    }
    // TODO: do I free this with XFreeColors???
    return color.pixel;
}
