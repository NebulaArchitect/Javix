// ============================================================
// 文件名: src/repl.zig
// ============================================================

const std = @import("std");
const config = @import("config.zig");
const Lexer = @import("compiler_core/lexer.zig").Lexer;
const Parser = @import("compiler_core/parser.zig").Parser;
const Node = @import("compiler_core/ast.zig").Node;
const SymbolTable = @import("compiler_core/ast.zig").SymbolTable;
const Token = @import("compiler_core/token.zig").Token;
const CodeGen = @import("compiler_core/codegen.zig").CodeGen;
const Executor = @import("compiler_core/executor.zig").Executor;
const printNode = @import("compiler_core/parser.zig").printNode;


pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {

    // ------ stdout writer ------
    var out_buf: [1024]u8 = undefined;
    const stdout_file = std.Io.File.stdout();
    var stdout_writer = std.Io.File.Writer.init(stdout_file, io, &out_buf);

    // ------ stdin reader ------
    var stdin_buf: [1024]u8 = undefined;
    const stdin_file = std.Io.File.stdin();
    var stdin_reader = std.Io.File.Reader.initStreaming(stdin_file, io, &stdin_buf);

    // 创建符号表（跨语句持久化）
    var sym_table = SymbolTable.init(allocator);
    defer sym_table.deinit();

    // 注册内置函数到符号表
    sym_table.registerBuiltins() catch |err| {
        try stdout_writer.interface.print("[ERROR] Failed to register builtins: {}\n", .{err});
        try stdout_writer.interface.flush();
        return;
    };

    // 创建执行器
    var executor = Executor.init(io, allocator);

    // 累积所有已输入的语句 AST（跨语句持久化执行）
    var all_stmts: std.ArrayListUnmanaged(*Node) = .empty;
    defer {
        for (all_stmts.items) |stmt| {
            // TODO: 递归释放 AST 内存
            _ = stmt;
        }
        all_stmts.deinit(allocator);
    }

    try stdout_writer.interface.writeAll("Javix REPL v0.1.0-alpha\n");
    try stdout_writer.interface.writeAll("Type 'exit' to quit\n");
    try stdout_writer.interface.flush();

    var line_buf: [4096]u8 = undefined;
    var line_len: usize = 0;
    var brace_depth: i32 = 0;          // 多行输入括号嵌套深度
    var multi_line_buf: [8192]u8 = undefined; // 多行累积缓冲区
    var multi_len: usize = 0;

    const prompt = ">>> ";
    const cont_prompt = "... ";

    try stdout_writer.interface.writeAll(prompt);
    try stdout_writer.interface.flush();

    while (true) {
        // 读取数据块（避免 Windows 单字节读取 ALERTED 问题）
        var read_buf: [256]u8 = undefined;
        var chunk_writer = std.Io.Writer.fixed(&read_buf);
        const n = stdin_reader.interface.stream(&chunk_writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => {
                try stdout_writer.interface.writeAll("\n");
                try stdout_writer.interface.flush();
                return;
            },
            else => return err,
        };
        if (n == 0) continue;

        for (read_buf[0..n]) |byte| {
            if (byte == '\n') {
                const line = line_buf[0..line_len];
                line_len = 0;

                const trimmed = std.mem.trim(u8, line, " \t\r");

                // 空行：如果正在多行输入则继续，否则显示新提示
                if (trimmed.len == 0) {
                    if (brace_depth > 0) {
                        try stdout_writer.interface.writeAll(cont_prompt);
                        try stdout_writer.interface.flush();
                        continue;
                    }
                    try stdout_writer.interface.writeAll(prompt);
                    try stdout_writer.interface.flush();
                    continue;
                }

                if (std.mem.eql(u8, trimmed, "exit")) {
                    try stdout_writer.interface.writeAll("Goodbye.\n");
                    try stdout_writer.interface.flush();
                    return;
                }

                // 计算本行的括号深度变化
                for (line) |c| {
                    if (c == '{') brace_depth += 1;
                    if (c == '}') brace_depth -= 1;
                }

                // 累积到多行缓冲区
                if (multi_len > 0) {
                    multi_line_buf[multi_len] = '\n';
                    multi_len += 1;
                }
                const copy_len = @min(line.len, multi_line_buf.len - multi_len);
                @memcpy(multi_line_buf[multi_len..multi_len + copy_len], line[0..copy_len]);
                multi_len += copy_len;

                // 如果括号未闭合，继续等待输入
                if (brace_depth > 0) {
                    try stdout_writer.interface.writeAll(cont_prompt);
                    try stdout_writer.interface.flush();
                    continue;
                }

                // 括号闭合，处理累积的完整输入
                const source = if (multi_len > 0) multi_line_buf[0..multi_len] else line;
                multi_len = 0;
                brace_depth = 0;

                // ====================================================
                // 词法分析
                // ====================================================
                var lexer = Lexer.init(allocator, source);
                var tokens: std.ArrayListUnmanaged(Token) = .empty;
                defer {
                    tokens.deinit(allocator);
                }

                while (true) {
                    const tok = lexer.nextToken() catch |err| {
                        try stdout_writer.interface.print("[ERROR] <repl>:{}:{}: lexer failed: {}\n", .{ lexer.line, lexer.column, err });
                        try stdout_writer.interface.flush();
                        break;
                    };
                    try tokens.append(allocator, tok);
                    if (tok.type == .eof) break;
                }

                // ====================================================
// 语法分析（传入符号表）
// ====================================================
                var parser = Parser.init(allocator, tokens.items, &sym_table);

                // 循环解析所有语句，打包成 Block
                var stmts: std.ArrayListUnmanaged(*Node) = .empty;
                defer stmts.deinit(allocator);

                var parse_ok = true;
                while (!parser.isAtEnd()) {
                    const stmt = parser.parseStatement() catch |err| {
                        const tok = parser.peek();
                        try stdout_writer.interface.print("[ERROR] <repl>:{}:{}: parser failed: {}\n", .{ tok.line, tok.column, err });
                        try stdout_writer.interface.flush();
                        parse_ok = false;
                        break;
                    };
                    if (stmt.* == .token_error) {
                        const tok = parser.previous();
                        try stdout_writer.interface.print("[ERROR] <repl>:{}:{}: {s}\n", .{ tok.line, tok.column, stmt.token_error });
                        try stdout_writer.interface.flush();
                        continue;
                    }
                    try stmts.append(allocator, stmt);
                }

                if (parse_ok) {
                    // 累积：定义/声明/赋值（保持状态）；不累积：控制流/表达式（避免回放）
                    for (stmts.items) |s| {
                        switch (s.*) {
                            .fn_def, .class_def, .enum_def, .interface_def, .package_stmt,
                            .var_decl, .assign, .member_assign, .array_assign => {
                                try all_stmts.append(allocator, s);
                            },
                            else => {},
                        }
                    }

                    // 构建 AST：历史定义 + 本次新语句（只执行新语句，不回放历史）
                    var combined_stmts: std.ArrayListUnmanaged(*Node) = .empty;
                    defer combined_stmts.deinit(allocator);
                    try combined_stmts.appendSlice(allocator, all_stmts.items);
                    try combined_stmts.appendSlice(allocator, stmts.items);

                    const ast = try allocator.create(Node);
                    ast.* = .{ .block = .{ .statements = combined_stmts.items } };
                    defer allocator.destroy(ast);

                    // 代码生成（编译全部累积语句）
                    var codegen = CodeGen.init(allocator, &sym_table);
                    defer codegen.deinit();
                    const zig_code = try codegen.generate(ast);

                    // 执行生成的代码
                    executor.executeZigCode(zig_code) catch |err| {
                        try stdout_writer.interface.writeAll("[EXEC ERROR] Failed to execute: ");
                        try stdout_writer.interface.print("{}\n", .{err});
                        try stdout_writer.interface.flush();
                    };
                }

                try stdout_writer.interface.writeAll(prompt);
                try stdout_writer.interface.flush();
            }
            else if (line_len < line_buf.len) {
                line_buf[line_len] = byte;
                line_len += 1;
            }
        }
    }
}

