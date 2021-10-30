const std = @import("std");
const os = std.os;
const Term = std.ChildProcess.Term;

pub fn open(flags: u32) !c_int {
    return os.openZ("/dev/ptmx", flags, undefined);
}

// The file descriptor number pt_chown expects for the master pseudoterm
const pt_chown_master_fd = 3;

const grant_process_exit_code_bad_fd = 2;
const grant_process_exit_code_exec_fail = 3;

pub fn grantpt(fd: c_int) !void {
    _ = fd;
//    std.log.debug("forking...", .{});
//    const pid = try os.fork();
//    std.log.debug("forked pid={}", .{pid});
//    if (pid == 0) {
//        // in the child process
//        // TODO: set rlimit to disable coredumpes?
//        // const rl = rlimit {0, 0};
//        // setrlimit(RLIMIT_CORE, &rl);
//        //
//        //os.exit(1);
//        if (fd != pt_chown_master_fd) {
//            switch (os.errno(os.system.dup2(fd, pt_chown_master_fd))) {
//                .SUCCESS => {},
//                else => os.exit(grant_process_exit_code_bad_fd),
//            }
//        }
//
//        // TODO: close all fds??
//
//        const pt_chown = "/pt_chown";
//        // TODO: I think os.execveZ needs to make the envp pointer optional
//        os.execveZ(
//            pt_chown,
//            &[_:null]?[*:0]const u8 {pt_chown, null},
//            &[_:null]?[*:0]const u8 {null},
//        ) catch {};
//        os.exit(grant_process_exit_code_exec_fail);
//    } else {
//        const wait_result = os.waitpid(pid, 0);
//        const term = statusToTerm(wait_result.status);
//        switch (term) {
//            .Exited => |code| switch (code) {
//                grant_process_exit_code_bad_fd => {
//                    std.log.err("badfd", .{});
//                    os.exit(0xff);
//                },
//                grant_process_exit_code_exec_fail => {
//                    std.log.err("execfail", .{});
//                    os.exit(0xff);
//                },
//                else => {
//                    std.log.err("bad exit {}", .{code});
//                    os.exit(0xff);
//                },
//            },
//            else => {
//                std.log.err("term = {}", .{term});
//                os.exit(0xff);
//            },
//       }
//    }
}

// NOTE: this is copied from std/child_process.zig (maybe it should be public?)
fn statusToTerm(status: u32) Term {
    return if (os.W.IFEXITED(status))
        Term{ .Exited = os.W.EXITSTATUS(status) }
    else if (os.W.IFSIGNALED(status))
        Term{ .Signal = os.W.TERMSIG(status) }
    else if (os.W.IFSTOPPED(status))
        Term{ .Stopped = os.W.STOPSIG(status) }
    else
        Term{ .Unknown = status };
}

const TIOCSPTLCK = 0x40045431;
const TIOCGPTN   = 0x80045430;
const TIOCSWINSZ = 0x5414;

pub fn unlockpt(fd: c_int) ?os.E {
    var unlock: c_int = 0;
    switch (os.errno(os.linux.ioctl(fd, TIOCSPTLCK, @ptrToInt(&unlock)))) {
        .SUCCESS => return null,
        else => |e| return e,
    }
}

pub fn getPtyNum(fd: c_int) !c_uint {
    var pty_num: c_uint = undefined;
    switch (os.errno(os.linux.ioctl(fd, TIOCGPTN, @ptrToInt(&pty_num)))) {
        .SUCCESS => return pty_num,
        else => |e| return os.unexpectedErrno(e),
    }
}

pub const PtyPath = struct {
    const prefix = "/dev/pts/";
    const max_num_digits = 20;
    const max_path = prefix.len + max_num_digits;
    const Len = std.math.IntFittingRange(0, max_path);

    path_buffer: [max_path + 1]u8,
    len: Len,

    pub fn init(num: c_uint) PtyPath {
        var result = PtyPath { .path_buffer = undefined, .len = undefined };
        const len = (std.fmt.bufPrintZ(&result.path_buffer, prefix ++ "{}", .{num}) catch unreachable).len;
        result.len = @intCast(Len, len);
        std.debug.assert(result.path_buffer[result.len] == 0);
        return result;
    }

    pub fn getSlice(self: *const PtyPath) [:0]const u8 {
        return self.path_buffer[0..self.len :0];
    }
    pub fn getPathZ(self: *const PtyPath) [*:0]const u8 {
        return std.meta.assumeSentinel(&self.path_buffer, 0);
    }

    pub fn open(self: *const PtyPath, flags: u32) !c_int {
        return os.openZ(self.getPathZ(), flags, undefined);
    }
};

pub fn setSize(master: c_int, height: u16, width: u16) ?os.E {
    var size = std.os.linux.winsize {
        .ws_row = height,
        .ws_col = width,
        .ws_xpixel = undefined,
        .ws_ypixel = undefined,
    };
    switch (os.errno(os.linux.ioctl(master, TIOCSWINSZ, @ptrToInt(&size)))) {
        .SUCCESS => return null,
        else => |e| return e,
    }
}
