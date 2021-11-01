const std = @import("std");
const pseudoterm = @import("pseudoterm.zig");
const CircularBuffer = @import("CircularBuffer.zig");

const x = @import("x");

const termlog = std.log.scoped(.term);
const termiolog = std.log.scoped(.termio);

pub const scope_levels = [_]std.log.ScopeLevel {
    .{ .scope = .x11, .level = .debug },
    .{ .scope = .term, .level = .info },
    .{ .scope = .termio, .level = .info },
    .{ .scope = .render, .level = .info },
};

const TermFds = struct {
    master: std.os.fd_t,
    slave: std.os.fd_t,
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

fn execShellNoreturn(slave: std.os.fd_t) noreturn {
    tryExecShell(slave) catch |err| {
        std.log.err("{s}", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
    };
    std.os.exit(0xff);
}
fn tryExecShell(slave: std.os.fd_t) !void {
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
    var window = x.Window.init();
    // TODO: do I need to setlocale?
    //_ = c.XSetLocaleModifiers("");

    const term_fds = openPseudoterm();
    if (pseudoterm.setSize(term_fds.master, window.cell_height, window.cell_width)) |err| {
        termlog.err("failed to set terminal size, errno={}", .{err});
        std.os.exit(0xff);
    }

    spawnShell(term_fds);
    std.os.close(term_fds.slave);

    try run(term_fds.master, &window);
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

fn run(term_fd_master: std.os.fd_t, window: *x.Window) !void {
    const maxfd = std.math.max(term_fd_master, window.fd) + 1;

    const buf_size = std.mem.alignForward(std.mem.page_size, 1024 * 1024);
    //const buf_size = std.mem.alignForward(std.mem.page_size, 1);
    var buf = try CircularBuffer.init(buf_size);

    while (true) {
        var readfds = FdSet.initEmpty();
        readfds.setValue(@intCast(usize, term_fd_master), true);
        readfds.setValue(@intCast(usize, window.fd), true);

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
            window.render(buf);
        }
        if (readfds.isSet(@intCast(usize, window.fd))) {
            window.onRead(term_fd_master, buf);
        }
    }
}

fn readPseudoterm(term_fd_master: std.os.fd_t, buf: *CircularBuffer) void {
    const read_len = std.os.read(term_fd_master, buf.next()) catch |err| {
        std.log.err("read from pseudoterm failed with {}", .{err});
        std.os.exit(0xff);
    };
    termiolog.debug("read {} bytes from pseudoterm", .{read_len});
    buf.scroll(read_len);
}
