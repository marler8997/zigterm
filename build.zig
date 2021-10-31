const std = @import("std");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("zigterm", "zigterm.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    const use_x11 = true;
    if (use_x11) {
        exe.linkSystemLibrary("c");
        exe.linkSystemLibrary("X11");
        exe.addPackagePath("x", "x11.zig");
    } else {
        std.log.err("not implemented");
        std.os.exit(0xff);
    }
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    var exe_tests = b.addTest("src/main.zig");
    exe_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&exe_tests.step);
}
