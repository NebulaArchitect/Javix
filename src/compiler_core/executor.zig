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

        const cwd = std.Io.Dir.cwd();
        const temp_dir_name = "javix_repl_temp";
        const temp_zig_name = "repl_temp.zig";
        const temp_exe_name = if (@import("builtin").os.tag == .windows) "repl_temp.exe" else "repl_temp";

        // 创建 temp 子目录（Zig 0.16.0 在驱动器根目录下有 bug，子目录避开）
        cwd.createDir(self.io, temp_dir_name, .default_file) catch {};
        defer cwd.deleteTree(self.io, temp_dir_name) catch {};

        var temp_dir = try cwd.openDir(self.io, temp_dir_name, .{});

        // 写入临时 zig 文件
        var zig_file = try temp_dir.createFile(self.io, temp_zig_name, .{ .read = true });
        defer zig_file.close(self.io);
        try zig_file.writeStreamingAll(self.io, zig_code);

        // 写入 javax runtime 文件
        var rt_file = try temp_dir.createFile(self.io, runtime_file_name, .{ .read = true });
        defer rt_file.close(self.io);
        try rt_file.writeStreamingAll(self.io, javax_runtime_source);

        // 编译（在 temp 子目录下执行）
        {
            var emit_arg_buf: [512]u8 = undefined;
            const emit_arg = try std.fmt.bufPrint(&emit_arg_buf, "-femit-bin={s}", .{temp_exe_name});

            var child = try std.process.spawn(self.io, .{
                .argv = &[_][]const u8{
                    "zig", "build-exe", temp_zig_name, emit_arg,
                    "-O", "ReleaseSmall",
                },
                .cwd = .{ .path = temp_dir_name },
            });
            _ = try child.wait(self.io);
        }

        // 运行生成的 exe
        {
            var exe_path_buf: [256]u8 = undefined;
            const exe_path = try std.fmt.bufPrint(&exe_path_buf, "{s}/{s}", .{ temp_dir_name, temp_exe_name });
            var run_child = try std.process.spawn(self.io, .{
                .argv = &[_][]const u8{exe_path},
            });
            _ = try run_child.wait(self.io);
        }
    }
};
