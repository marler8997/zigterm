const std = @import("std");
const GitRepoStep = @import("GitRepoStep.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const options = b.addOptions();
    const termlog = if (b.option(bool, "termlog", "Enable term logs")) |o| o else false;
    options.addOption(bool, "termlog", termlog);

    const exe = b.addExecutable("zigterm", "zigterm.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.addOptions("options", options);

    {
        const zigx_repo = GitRepoStep.create(b, .{
            .url = "https://github.com/marler8997/zigx",
            .branch = null,
            .sha = "175949a89143e693ee017e19d21e382d1077dec8",
        });
        exe.step.dependOn(&zigx_repo.step);
        const zigx_path = zigx_repo.getPath(&exe.step);
        const index_file = std.fs.path.join(b.allocator, &.{ zigx_path, "x.zig" }) catch unreachable;
        exe.addPackagePath("x", index_file);
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
