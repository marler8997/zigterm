const std = @import("std");
const builtin = @import("builtin");

const x11 = @import("x");
const Memfd = x11.Memfd;
const CircularBuffer = x11.CircularBuffer;

const shell = @import("shell.zig");
const CharGrid = @import("CharGrid.zig");
const Window = @import("Window.zig");

const termlog = std.log.scoped(.term);
const termiolog = std.log.scoped(.termio);

pub const scope_levels = [_]std.log.ScopeLevel {
    .{ .scope = .x11, .level = .info },
    .{ .scope = .term, .level = .info },
    .{ .scope = .termio, .level = .info },
    .{ .scope = .render, .level = .info },
};

pub fn main() anyerror!void {
    // I'm spawning the shell first thing because
    // on linux this might make it easier because we don't have to
    // cleanup any file descriptors (I think, but not sure)
    const shell_fd = try shell.spawnShell();

    const grid = try CharGrid.init(std.heap.page_allocator, 80, 25);
    var window = try Window.init(grid);
    // TODO: do I need to setlocale?
    //_ = c.XSetLocaleModifiers("");

    // TODO: is this necessary if we support "automatic margins"?
    //shell.setSize(shell_fd, grid.width, grid.height);

    try run(shell_fd, &window);
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

fn run(shell_fd: std.os.fd_t, window: *Window) !void {
    const maxfd = if (builtin.os.tag == .windows) void else (std.math.max(shell_fd, window.sock) + 1);

    const buf_memfd = try Memfd.init("zigtermCircularBuffer");
    // no need to deinit

    const buf_size = std.mem.alignForward(std.mem.page_size, 1024 * 1024);
    //const buf_size = std.mem.alignForward(std.mem.page_size, 1);
    var buf = try CircularBuffer.init(buf_memfd, buf_size);

    while (true) {
        var readfds = FdSet.initEmpty();
        if (builtin.os.tag == .windows) {
            @panic("not implemented");
        } else {
            readfds.setValue(@intCast(usize, shell_fd), true);
            readfds.setValue(@intCast(usize, window.sock), true);
        }

        //std.log.info("waiting for something...", .{});
        switch (std.os.errno(pselect6(maxfd, &readfds, null, null, null, null))) {
            .SUCCESS => {},
            else => |errno| {
                std.log.err("select failed, errno={}", .{errno});
                std.os.exit(0xff);
            },
        }
        if (readfds.isSet(@intCast(usize, shell_fd))) {
            readPseudoterm(shell_fd, &buf);
            // TODO: instead of doing a blocking render, I could
            //       schedule it to be done when the previous render
            //       is complete.
            window.render(buf);
        }
        if (readfds.isSet(@intCast(usize, window.sock))) {
            window.onRead(shell_fd, buf);
        }
    }
}

fn readPseudoterm(shell_fd: std.os.fd_t, buf: *CircularBuffer) void {
    const read_len = std.os.read(shell_fd, buf.next()) catch |err| {
        std.log.err("read from pseudoterm failed with {}", .{err});
        std.os.exit(0xff);
    };
    if (read_len == 0) {
        std.log.info("pseudoterm is closed", .{});
        std.os.exit(0);
    }
    termiolog.debug("read {} bytes from pseudoterm", .{read_len});
    _ = buf.scroll(read_len);
}
