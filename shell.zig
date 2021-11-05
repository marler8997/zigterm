const std = @import("std");
const builtin = @import("builtin");

const pseudoterm = @import("pseudoterm.zig");

const termlog = std.log.scoped(.term);
const termiolog = std.log.scoped(.termio);

pub fn spawnShell() !std.os.fd_t {
    if (builtin.os.tag == .windows) {
        termlog.err("todo: implement the pseudoterm on windows", .{});
        std.os.exit(0xff);
    } else {
        const term_fds = openPseudoterm();
        const pid = std.os.fork() catch |err| {
            std.log.err("failed to fork shell process: {}", .{err});
            std.os.exit(0xff);
        };
        if (pid == 0) {
            // the child process
            std.os.close(term_fds.master);
            execShellNoreturn(term_fds.slave);
        }
        termlog.info("started shell, pid={}", .{pid});
        std.os.close(term_fds.slave);
        return term_fds.master;
    }
}

pub fn setSize(shell_fd: std.os.fd_t, width: u16, height: u16) void {
    if (builtin.os.tag == .windows)
        @compileError("not implemented");

    if (pseudoterm.setSize(shell_fd, height, width)) |err| {
        termlog.err("failed to set terminal size, errno={}", .{err});
        std.os.exit(0xff);
    }
}

const TermFds = struct {
    master: std.os.fd_t,
    slave: std.os.fd_t,
};

fn openPseudoterm() TermFds {
    if (builtin.os.tag == .windows)
        @panic("not implemented");

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
    const pty_path_slice = pty_path.getSlice();
    termlog.info("pty path is '{s}'", .{pty_path_slice});

    const slave = pty_path.open(std.os.O.RDWR | std.os.O.NOCTTY) catch |err| {
        termlog.err("failed to open pty slave '{s}': {}", .{pty_path_slice, err});
        std.os.exit(0xff);
    };

    return TermFds{
        .master = master,
        .slave = slave,
    };
}

pub fn setsid() usize {
    return std.os.linux.syscall0(.setsid);
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

    const shell: [*:0]const u8 = blk: {
        for (std.os.environ) |env| {
            if (cstrStartsWith(env, "SHELL=")) {
                // TODO: in this case other terms support searching for the shell in $PATH
                break :blk env + 6;
            }
        }
        // TODO: should we check whether this exists?
        break :blk "/bin/sh";
    };
    termlog.err("shell is '{s}'", .{shell});

    // NOTE: from this point we can no longer log to the parent process
    try std.os.dup2(slave, 0);
    try std.os.dup2(slave, 1);
    try std.os.dup2(slave, 2);
    std.os.close(slave);

    // set the TERM environment variable
    //const env = makeEnvWithTerm("TERM=dumb");
    const env = makeEnvWithTerm("TERM=zigterm");

    std.os.execveZ(shell, &[_:null]?[*:0]const u8 {shell, null}, env) catch {};
}

fn makeEnvWithTerm(term: [*:0]const u8) [*:null]const ?[*:0]const u8 {
    const new_env = std.heap.page_allocator.alloc(?[*:0]const u8, std.os.environ.len + 2) catch @panic("Out Of Memory");
    var set_term = false;
    var i: usize = 0;
    while (i < std.os.environ.len) : (i += 1) {
        const env = std.os.environ[i];
        if (cstrStartsWith(env, "TERM=")) {
            new_env[i] = term;
            set_term = true;
        } else {
            new_env[i] = env;
        }
    }
    if (!set_term) {
        new_env[i] = term;
        i += 1;
    }
    new_env[i] = null;
    return std.meta.assumeSentinel(new_env.ptr, null);
}

// NOTE: what must not contain the 0 character to prevent from reading past 0 on cstr
fn cstrStartsWith(cstr: [*:0]const u8, what: []const u8) bool {
    var i: usize = 0;
    while (i < what.len) : (i += 1) {
        if (cstr[i] != what[i]) return false;
    }
    return true;
}

const termiowrite_filename = "termiowrite.bin";
const enable_termio_log = true;
var termio_log_file:
    if (enable_termio_log) ?std.fs.File else ?struct { } =
    if (enable_termio_log) null else .{};
fn log_write(buf: []const u8) void {
    if (enable_termio_log) {
        const file = termio_log_file orelse std.fs.cwd().createFile(termiowrite_filename, .{}) catch |err|
            std.debug.panic("failed to create '{s}': {s}", .{termiowrite_filename, @errorName(err)});
        const len = file.write(buf) catch |err|
            std.debug.panic("failed to write {} bytes to {s}: {s}", .{buf.len, termiowrite_filename, @errorName(err)});
        if (len != buf.len)
            std.debug.panic("only wrote {} byte(s) out of {} {s}", .{len, buf.len, termiowrite_filename});
    }
}

pub fn write(fd: std.os.fd_t, buf: []const u8) void {
    const len = std.os.write(fd, buf) catch |err| {
        termiolog.err("write to pseudoterm failed with {}", .{err});
        std.os.exit(0xff);
    };
    if (len > 0)
        log_write(buf[0 .. len]);
    // TODO: need to implement a loop to write the entire buffer
    //       and potentially use select or poll to wait for it to be
    //       writeable if we fail
    if (len != buf.len) {
        termiolog.err("only wrote {} byte(s) out of {} to pseudoterm (TODO: handle this)", .{len, buf.len});
        std.os.exit(0xff);
    }
}
