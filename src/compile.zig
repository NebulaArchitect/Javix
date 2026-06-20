// ============================================================
// 文件名: src/compile.zig
// ============================================================

const std = @import("std");
const Lexer = @import("compiler_core/lexer.zig").Lexer;
const Parser = @import("compiler_core/parser.zig").Parser;
const Token = @import("compiler_core/token.zig").Token;
const Node = @import("compiler_core/ast.zig").Node;
const SymbolTable = @import("compiler_core/ast.zig").SymbolTable;
const CodeGen = @import("compiler_core/codegen.zig").CodeGen;

// 将 javax runtime 源码嵌入到二进制中，运行时按需写出，
// 避免依赖 CWD 路径解析 @import
const javax_runtime_source = @embedFile("runtime/javax_runtime.zig");
const runtime_file_name = "javax_runtime.zig";

pub fn build(io: std.Io, parent_allocator: std.mem.Allocator, source_path: []const u8, wasm: bool) !void {
    // Arena: 整个编译流程的内存统一管理，函数结束自动全部释放
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var out_buf: [1024]u8 = undefined;
    var stdout = std.Io.File.Writer.init(std.Io.File.stdout(), io, &out_buf);

    // ------------------------------------------------------------
    // 1. 读取 .jx 源文件
    // ------------------------------------------------------------
    const cwd = std.Io.Dir.cwd();

    const stat = cwd.statFile(io, source_path, .{}) catch |err| {
        try stdout.interface.print("Error: cannot open '{s}': {}\n", .{ source_path, err });
        try stdout.interface.flush();
        return;
    };

    const buf = allocator.alloc(u8, @intCast(stat.size)) catch {
        try stdout.interface.print("Error: out of memory\n", .{});
        try stdout.interface.flush();
        return;
    };
    const source = cwd.readFile(io, source_path, buf) catch |err| {
        try stdout.interface.print("Error: cannot read '{s}': {}\n", .{ source_path, err });
        try stdout.interface.flush();
        return;
    };

    // ------------------------------------------------------------
    // 2. 词法分析
    // ------------------------------------------------------------
    var lexer = Lexer.init(allocator, source);
    var tokens: std.ArrayListUnmanaged(Token) = .empty;

    while (true) {
        const tok = lexer.nextToken() catch |err| {
            try stdout.interface.print("Error: {s}:{}:{}: lexer failed: {}\n", .{ source_path, lexer.line, lexer.column, err });
            try stdout.interface.flush();
            return;
        };
        const is_eof = tok.type == .eof;
        try tokens.append(allocator, tok);
        if (is_eof) break;
    }

    // ------------------------------------------------------------
    // 3. 语法分析
    // ------------------------------------------------------------
    var sym_table = SymbolTable.init(allocator);

    // 注册内置函数到符号表
    try sym_table.registerBuiltins();

    var parser = Parser.init(allocator, tokens.items, &sym_table);
    var stmts: std.ArrayListUnmanaged(*Node) = .empty;

    while (!parser.isAtEnd()) {
        const stmt = parser.parseStatement() catch |err| {
            const tok = parser.peek();
            try stdout.interface.print("Error: {s}:{}:{}: parser failed: {}\n", .{ source_path, tok.line, tok.column, err });
            try stdout.interface.flush();
            return;
        };
        if (stmt.* == .token_error) {
            const tok = parser.previous();
            try stdout.interface.print("Error: {s}:{}:{}: {s}\n", .{ source_path, tok.line, tok.column, stmt.token_error });
            try stdout.interface.flush();
            continue;
        }
        try stmts.append(allocator, stmt);
    }

    if (stmts.items.len == 0) {
        try stdout.interface.print("Error: no valid statements found in '{s}'\n", .{source_path});
        try stdout.interface.flush();
        return;
    }

    // ------------------------------------------------------------
    // 3.5. 处理 import 语句（收集导入文件，递归解析，循环检测）
    // ------------------------------------------------------------
    {
        var imported_paths = std.StringHashMap(void).init(allocator);
        defer imported_paths.deinit();

        var i: usize = 0;
        while (i < stmts.items.len) {
            const stmt = stmts.items[i];
            if (stmt.* == .import_stmt) {
                const import_path = stmt.import_stmt;
                // 解析相对于源文件目录的路径
                const src_dir = std.fs.path.dirname(source_path) orelse ".";
                const resolved = try std.fs.path.resolve(allocator, &[_][]const u8{ src_dir, import_path });

                // 循环引用检测：已导入的文件跳过
                if (imported_paths.contains(resolved)) {
                    i += 1;
                    continue;
                }
                try imported_paths.put(resolved, {});

                // 读取导入文件
                const istat = cwd.statFile(io, resolved, .{}) catch |err| {
                    try stdout.interface.print("Error: cannot import '{s}': {}\n", .{ resolved, err });
                    try stdout.interface.flush();
                    return;
                };
                const ibuf = allocator.alloc(u8, @intCast(istat.size)) catch {
                    try stdout.interface.print("Error: out of memory\n", .{});
                    return;
                };
                const isource = cwd.readFile(io, resolved, ibuf) catch |err| {
                    try stdout.interface.print("Error: cannot read '{s}': {}\n", .{ resolved, err });
                    return;
                };

                // 词法+语法分析导入文件
                var ilexer = Lexer.init(allocator, isource);
                var itokens: std.ArrayListUnmanaged(Token) = .empty;
                while (true) {
                    const itok = ilexer.nextToken() catch |err| {
                        try stdout.interface.print("Error: {s}:{}:{}: lexer failed: {}\n", .{ resolved, ilexer.line, ilexer.column, err });
                        return;
                    };
                    const ieof = itok.type == .eof;
                    try itokens.append(allocator, itok);
                    if (ieof) break;
                }

                var iparser = Parser.init(allocator, itokens.items, &sym_table);
                while (!iparser.isAtEnd()) {
                    const istmt = iparser.parseStatement() catch |err| {
                        const itok = iparser.peek();
                        try stdout.interface.print("Error: {s}:{}:{}: parser failed: {}\n", .{ resolved, itok.line, itok.column, err });
                        return;
                    };
                    if (istmt.* == .token_error) {
                        const itok = iparser.previous();
                        try stdout.interface.print("Error: {s}:{}:{}: {s}\n", .{ resolved, itok.line, itok.column, istmt.token_error });
                        continue;
                    }
                    // 导入文件的 import 也递归处理（通过 append 回到外层循环）
                    if (istmt.* == .import_stmt) {
                        try stmts.append(allocator, istmt);
                    } else {
                        try stmts.append(allocator, istmt);
                    }
                }
            }
            i += 1;
        }
    }

    // ------------------------------------------------------------
    // 4. 构建 AST 并代码生成
    // ------------------------------------------------------------
    const ast = try allocator.create(Node);
    ast.* = .{ .block = .{ .statements = try stmts.toOwnedSlice(allocator) } };

    var codegen = CodeGen.init(allocator, &sym_table);
    const zig_code = try codegen.generate(ast);

    // ------------------------------------------------------------
    // 5. 推导输出文件路径
    // ------------------------------------------------------------
    const stem = std.fs.path.stem(source_path);
    const out_ext: []const u8 = if (wasm) ".wasm" else if (@import("builtin").os.tag == .windows) ".exe" else "";
    const out_path = try std.fmt.allocPrint(allocator, "{s}{s}", .{ stem, out_ext });

    // ------------------------------------------------------------
    // 6. 在 temp 子目录中编译（Zig 0.16.0 在驱动器根目录下有 bug）
    // ------------------------------------------------------------
    try stdout.interface.print("Compiling {s} ...\n", .{source_path});
    try stdout.interface.flush();

    const build_temp_dir = "javix_build_temp";
    {
        // 创建 temp 子目录
        cwd.createDir(io, build_temp_dir, .default_file) catch {};
        defer cwd.deleteTree(io, build_temp_dir) catch {};

        var temp_dir = try cwd.openDir(io, build_temp_dir, .{});
        const temp_zig_name = "source.zig";
        const temp_exe_name = if (wasm) "out.wasm" else if (@import("builtin").os.tag == .windows) "out.exe" else "out";

        // 写入 zig 源码 + runtime 文件
        {
            var f = try temp_dir.createFile(io, temp_zig_name, .{ .read = true });
            defer f.close(io);
            try f.writeStreamingAll(io, zig_code);
        }
        {
            var f = try temp_dir.createFile(io, runtime_file_name, .{ .read = true });
            defer f.close(io);
            try f.writeStreamingAll(io, javax_runtime_source);
        }

        // 编译
        {
            var emit_arg_buf: [512]u8 = undefined;
            const emit_arg = try std.fmt.bufPrint(&emit_arg_buf, "-femit-bin={s}", .{temp_exe_name});

            if (wasm) {
                var child = try std.process.spawn(io, .{
                    .argv = &[_][]const u8{
                        "zig", "build-exe", temp_zig_name, emit_arg,
                        "-target", "wasm32-wasi",
                        "-O", "ReleaseSmall",
                    },
                    .cwd = .{ .path = build_temp_dir },
                });
                _ = try child.wait(io);
            } else {
                var child = try std.process.spawn(io, .{
                    .argv = &[_][]const u8{
                        "zig", "build-exe", temp_zig_name, emit_arg,
                        "-O", "ReleaseSmall",
                    },
                    .cwd = .{ .path = build_temp_dir },
                });
                _ = try child.wait(io);
            }
        }

        // 移动输出文件到目标位置
        {
            const temp_exe_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ build_temp_dir, temp_exe_name });
            // 如果目标已存在（比如上次编译的），先删掉
            cwd.deleteFile(io, out_path) catch {};
            try cwd.rename(temp_exe_path, cwd, out_path, io);
        }
    }

    // ------------------------------------------------------------
    // 8. 清理（暂时保留 .zig 文件用于调试）
    // ------------------------------------------------------------
    // cwd.deleteFile(io, zig_path) catch {};

    try stdout.interface.print("OK  {s}  ->  {s}\n", .{ source_path, out_path });
    try stdout.interface.flush();
}
