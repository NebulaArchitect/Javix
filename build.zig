// ============================================================
// 文件名: build.zig
// 适配 Zig 0.16.0
// ============================================================

const std = @import("std");

pub fn build(b: *std.Build) void {
    // 目标平台：默认当前系统
    const target = b.standardTargetOptions(.{});

    // 优化模式：Debug 阶段用 .debug，后续可切 .release_fast
    const optimize = b.standardOptimizeOption(.{});

    // ========================================================
    // 创建可执行文件（Zig 0.16.0 新语法）
    // ========================================================
    const exe = b.addExecutable(.{
        .name = "javix",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // 安装到 zig-out/bin
    b.installArtifact(exe);

    // ========================================================
    // 运行命令：zig build run
    // ========================================================
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run javix");
    run_step.dependOn(&run_cmd.step);

    // ========================================================
    // 测试
    // ========================================================
    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_exe_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_tests.step);
}
