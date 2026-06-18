// ============================================================
// 文件名: main.zig
// ============================================================

const std = @import("std");
const errors = @import("errors.zig");
const config = @import("config.zig");
const repl = @import("repl.zig");
const compile = @import("compile.zig");

// ------------------------------------------------------------
// 程序主入口（Zig 0.16.0 新方式）
// ------------------------------------------------------------
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    // 项目根目录（绝对路径，用于 CodeGen import javax runtime）

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args_iter.deinit();

    // 跳过第一个参数（程序名）
    _ = args_iter.next() orelse unreachable;

    // 检查是否有第二个参数
    const second_arg = args_iter.next();

    if (second_arg == null) {
        // 无参数：默认进入 REPL 模式
        try repl.run(io, allocator);
        return;
    }

    const subcommand = second_arg.?;

    // repl 子命令
    if (std.mem.eql(u8, subcommand, "repl")) {
        try repl.run(io, allocator);
        return;
    }

    // build 子命令：javix build test.jx [--wasm]
    if (std.mem.eql(u8, subcommand, "build")) {
        const file_arg = args_iter.next();
        if (file_arg == null) {
            var err_buf: [1024]u8 = undefined;
            var err_writer = std.Io.File.Writer.init(std.Io.File.stderr(), io, &err_buf);
            try err_writer.interface.writeAll("用法: javix build <文件.jx> [--wasm]\n");
            try err_writer.interface.flush();
            std.process.exit(1);
        }
        var wasm_target = false;
        // 检查后续参数是否有 --wasm
        var next_arg = args_iter.next();
        while (next_arg) |arg| : (next_arg = args_iter.next()) {
            if (std.mem.eql(u8, arg, "--wasm")) {
                wasm_target = true;
            }
        }
        try compile.build(io, allocator, file_arg.?, wasm_target);
        return;
    }

    // 文件编译模式：javix xxx.jx（直接传文件路径）
    if (std.mem.endsWith(u8, subcommand, ".jx")) {
        try compile.build(io, allocator, subcommand, false);
        return;
    }

    // 未知命令
    var err_buf: [1024]u8 = undefined;
    var err_writer = std.Io.File.Writer.init(std.Io.File.stderr(), io, &err_buf);
    try err_writer.interface.writeAll("未知命令: ");
    try err_writer.interface.writeAll(subcommand);
    try err_writer.interface.writeAll("\n用法:\n");
    try err_writer.interface.writeAll("  javix                 启动 REPL 交互模式\n");
    try err_writer.interface.writeAll("  javix repl            启动 REPL 交互模式\n");
    try err_writer.interface.writeAll("  javix build <文件.jx> 编译 Javix 文件为可执行文件\n");
    try err_writer.interface.writeAll("  javix <文件.jx>       编译 Javix 文件（简写）\n");
    try err_writer.interface.writeAll("  javix --help          显示帮助\n");
    try err_writer.interface.flush();
    std.process.exit(1);
}
