// ============================================================
// 文件名: src/compiler_core/executor.zig
// ============================================================

const std = @import("std");

// 将 javax runtime 源码嵌入到二进制中，运行时按需写出，
// 避免依赖 CWD 路径解析 @import
const javax_runtime_source = @embedFile("../runtime/javax_runtime.zig");
const runtime_file_name = "javax_runtime.zig";

pub const Executor = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    debug_print_code: bool = false,

    pub fn init(io: std.Io, allocator: std.mem.Allocator) Executor {
        return Executor{
            .io = io,
            .allocator = allocator,
            .debug_print_code = false,
        };
    }

    /// 执行 Zig 代码字符串（编译 + 运行 + 清理）
    pub fn executeZigCode(self: *Executor, zig_code: []const u8) !void {
        // 可选：打印生成的代码用于调试
        if (self.debug_print_code) {
            var out_buf: [1024]u8 = undefined;
            var stdout_writer = std.Io.File.Writer.init(std.Io.File.stdout(), self.io, &out_buf);
            try stdout_writer.interface.writeAll("--- Zig Code ---\n");
            try stdout_writer.interface.writeAll(zig_code);
            try stdout_writer.interface.writeAll("--- End ---\n");
            try stdout_writer.interface.flush();
        }

        // 当前工作目录（temp 文件写入这里）
        const cwd = std.Io.Dir.cwd();
        const temp_zig_path = "javix_repl_temp.zig";
        const temp_exe_path = "javix_repl_temp.exe";

        // 写入临时 Zig 文件
        var temp_file = try cwd.createFile(self.io, temp_zig_path, .{ .read = true });
        defer temp_file.close(self.io);
        try temp_file.writeStreamingAll(self.io, zig_code);

        // 写入 javax runtime 文件（与 temp zig 文件同目录，供 @import 解析）
        var rt_file = try cwd.createFile(self.io, runtime_file_name, .{ .read = true });
        defer rt_file.close(self.io);
        try rt_file.writeStreamingAll(self.io, javax_runtime_source);

        // 编译 Zig 代码
        try self.compileZigFile(temp_zig_path, temp_exe_path);

        // 运行生成的 exe
        try self.runExecutable(temp_exe_path);

        // 清理临时文件
        cwd.deleteFile(self.io, temp_zig_path) catch {};
        cwd.deleteFile(self.io, temp_exe_path) catch {};
        cwd.deleteFile(self.io, runtime_file_name) catch {};
    }

    /// 编译 Zig 文件为可执行文件
    fn compileZigFile(self: *Executor, source_path: []const u8, output_path: []const u8) !void {
        // 构建参数字符串 "-femit-bin=xxx"
        var emit_arg_buf: [512]u8 = undefined;
        const emit_arg = try std.fmt.bufPrint(&emit_arg_buf, "-femit-bin={s}", .{output_path});
        
        var child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{
                "zig",
                "build-exe",
                source_path,
                emit_arg,
                "-O",
                "ReleaseSmall",
            },
        });
        _ = try child.wait(self.io);
    }

    /// 运行可执行文件
    fn runExecutable(self: *Executor, exe_path: []const u8) !void {
        var run_child = try std.process.spawn(self.io, .{
            .argv = &[_][]const u8{ exe_path },
        });
        _ = try run_child.wait(self.io);
    }
};
