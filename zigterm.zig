const std = @import("std");
const pseudoterm = @import("pseudoterm.zig");
const CircularBuffer = @import("CircularBuffer.zig");

const x11log = std.log.scoped(.x11);
const termlog = std.log.scoped(.term);
const termiolog = std.log.scoped(.termio);
const renderlog = std.log.scoped(.render);

pub const scope_levels = [_]std.log.ScopeLevel {
    .{ .scope = .x11, .level = .info },
    .{ .scope = .term, .level = .info },
    .{ .scope = .termio, .level = .info },
    .{ .scope = .render, .level = .info },
};

const c = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
});

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

const X11 = struct {
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

    pub fn drawString(self: X11, x: c_int, y: c_int, str: []const u8) void {
        _ = c.XDrawString(self.display, self.window, self.gc, x, y, str.ptr, @intCast(c_int, str.len));
        // TODO: handle error
    }
};

fn createX11Window() X11 {
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

    _ = graphics_context;
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

fn x11AllocColor(display: *c.Display, colormap: c.Colormap, color_name: [*:0]const u8) c_ulong {
    var color: c.XColor = undefined;
    if (0 == c.XAllocNamedColor(display, colormap, color_name, &color, &color)) {
        x11log.err("XAllocNamedColor for '{s}' failed (todo: get error info)", .{color_name});
        std.os.exit(0xff);
    }
    // TODO: do I free this with XFreeColors???
    return color.pixel;
}

const TermFds = struct {
    master: c_int,
    slave: c_int,
};

fn openPseudoterm() TermFds {
    const master = pseudoterm.open(std.os.O.RDWR | std.os.O.NOCTTY) catch |err| {
        termlog.err("failed to open pseudoterm: {}", .{err});
        std.os.exit(0xff);
    };

    pseudoterm.grantpt(master) catch |err| {
        termlog.err("grantpt failed with {}", .{err});
        std.os.exit(0xff);
    };
    if (pseudoterm.unlockpt(master)) |errno| {
        termlog.err("unlockpt failed, errno={}", .{errno});
        std.os.exit(0xff);
    }

    const master_num = pseudoterm.getPtyNum(master) catch |err| {
        termlog.err("failed to get pty num for fd={}, error={}", .{master, err});
        std.os.exit(0xff);
    };
    termlog.info("pty number is {}", .{master_num});

    const pty_path = pseudoterm.PtyPath.init(master_num);
    termlog.info("pty path is '{s}'", .{pty_path.getSlice()});

    const slave = pty_path.open(std.os.O.RDWR | std.os.O.NOCTTY) catch |err| {
        termlog.err("failed to open pty slave '{s}': {}", .{pty_path.getSlice(), err});
        std.os.exit(0xff);
    };

    return TermFds{
        .master = master,
        .slave = slave,
    };
}

fn execShellNoreturn(slave: c_int) noreturn {
    tryExecShell(slave) catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
    std.os.exit(0xff);
}
fn tryExecShell(slave: c_int) !void {
    switch (std.os.errno(setsid())) {
        .SUCCESS => {},
        else => |errno| {
            std.log.err("setsid failed, errno={}", .{errno});
            std.os.exit(0xff);
        },
    }

    try std.os.dup2(slave, 0);
    try std.os.dup2(slave, 1);
    try std.os.dup2(slave, 2);
    std.os.close(slave);

    // TODO: this shell needs to be customizeable somehow, maybe there is already an environment variable?
    //       if there is, it should be documented in the usage help
    // TODO: forward the current env
    std.os.execveZ(
        "/bin/sh",
        &[_:null]?[*:0]const u8 {"/bin/sh", null},
        @ptrCast([*:null]const ?[*:0]const u8, std.os.environ.ptr),
        //&[_:null]?[*:0]const u8 {null},
    ) catch {};
}

fn spawnShell(term_fds: TermFds) void {
    const pid = std.os.fork() catch |err| {
        std.log.err("failed to fork shell process: {}", .{err});
        std.os.exit(0xff);
    };
    if (pid == 0) {
        // the child process
        std.os.close(term_fds.master);
        execShellNoreturn(term_fds.slave);
    }
}


pub fn main() anyerror!void {
    const x11 = createX11Window();
    // TODO: do I need to setlocale?
    //_ = c.XSetLocaleModifiers("");

    const term_fds = openPseudoterm();
    if (pseudoterm.setSize(term_fds.master, x11.cell_height, x11.cell_width)) |err| {
        termlog.err("failed to set terminal size, errno={}", .{err});
        std.os.exit(0xff);
    }

    spawnShell(term_fds);
    std.os.close(term_fds.slave);

    try run(term_fds.master, x11);
}

// TODO: move this stuff to std
// NOTE: it's lucky that StaticBitSet has the right memory layout
//       it may not in the future or on some platforms
const FdSet = std.StaticBitSet(1024);
comptime {
    // make sure FdSet is correct
    std.debug.assert(@sizeOf(FdSet) == 1024 / 8);
}
pub fn pselect6(
    nfds: isize,
    readfds: ?*FdSet,
    writefds: ?*FdSet,
    exceptfds: ?*FdSet,
    timeout: ?*const std.os.linux.timespec,
    sigmask: ?*const std.os.linux.sigset_t,
) usize {
    return std.os.linux.syscall6(
        .pselect6,
        @bitCast(usize, nfds),
        @ptrToInt(readfds),
        @ptrToInt(writefds),
        @ptrToInt(exceptfds),
        @ptrToInt(timeout),
        @ptrToInt(sigmask),
     );
}
pub fn setsid() usize {
    return std.os.linux.syscall0(.setsid);
}

fn run(term_fd_master: c_int, x11: X11) !void {
    const maxfd = std.math.max(term_fd_master, x11.fd) + 1;

    const buf_size = std.mem.alignForward(std.mem.page_size, 1024 * 1024);
    //const buf_size = std.mem.alignForward(std.mem.page_size, 1);
    var buf = try CircularBuffer.init(buf_size);

    while (true) {
        var readfds = FdSet.initEmpty();
        readfds.setValue(@intCast(usize, term_fd_master), true);
        readfds.setValue(@intCast(usize, x11.fd), true);

        //std.log.info("waiting for something...", .{});
        switch (std.os.errno(pselect6(maxfd, &readfds, null, null, null, null))) {
            .SUCCESS => {},
            else => |errno| {
                std.log.err("select failed, errno={}", .{errno});
                std.os.exit(0xff);
            },
        }
        if (readfds.isSet(@intCast(usize, term_fd_master))) {
            readPseudoterm(term_fd_master, &buf);
            // TODO: instead of doing a blocking render, I could
            //       schedule it to be done when the previous render
            //       is complete.
            render(x11, buf);
        }
        if (readfds.isSet(@intCast(usize, x11.fd))) {
            while (c.XPending(x11.display) != 0) {
                readXEvent(term_fd_master, x11, buf);
            }
        }
    }
}

fn readPseudoterm(term_fd_master: c_int, buf: *CircularBuffer) void {
    const read_len = std.os.read(term_fd_master, buf.next()) catch |err| {
        std.log.err("read from pseudoterm failed with {}", .{err});
        std.os.exit(0xff);
    };
    termiolog.debug("read {} bytes from pseudoterm", .{read_len});
    buf.scroll(read_len);
}

fn readXEvent(term_fd_master: c_int, x11: X11, buf: CircularBuffer) void {
    var generic_event: c.XEvent = undefined;

    _ = c.XNextEvent(x11.display, &generic_event);
    // TODO: handle return value?

    switch (generic_event.type) {
        c.Expose => {
            render(x11, buf);
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

fn render(x11: X11, buf: CircularBuffer) void {
    renderlog.debug("render!", .{});
    _ = c.XSetForeground(x11.display, x11.gc, x11.background_pixel);
    // TODO: check for error

    _ = c.XFillRectangle(
        x11.display,
        x11.window,
        x11.gc,
        0, 0,
        x11.pixel_width,
        x11.pixel_height,
    );
    // TODO: check for error

    _ = c.XSetForeground(x11.display, x11.gc, x11.foreground_pixel);
    // TODO: check for error

    {
        var start = buf.ptr;
        var cursor = blk: {
            if (buf.cursor < buf.size)
                break :blk start + buf.cursor;
            start += buf.cursor;
            break :blk start + buf.size;
        };

        var y_cell = x11.cell_height;
        while (true) {
            if (y_cell == 0) {
                // done drawing to the view
                break;
            }
            y_cell -= 1;
            const y = x11.font_ascent + (x11.font_height * y_cell);
            if (toNewline(start, cursor)) |newline| {
                const line_start = newline + 1;
                const line_len = @ptrToInt(cursor) - @ptrToInt(line_start);
                x11.drawString(0, y, line_start[0 .. line_len]);
                cursor = newline - 1;
            } else {
                const line_len = @ptrToInt(cursor) - @ptrToInt(start);
                x11.drawString(0, y, start[0 .. line_len]);
                break;
            }
        }
    }

    _ = c.XSync(x11.display, 0);
    // TODO: check for error
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
