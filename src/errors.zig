// ============================================================
// 文件名: errors.zig
// ============================================================

const std = @import("std");

// ------------------------------------------------------------
// 错误类型枚举
// ------------------------------------------------------------
pub const ErrorKind = enum {
    generic,        // 通用错误
    io,             // 文件读写错误
    lexer,          // 词法错误（非法字符、未闭合字符串）
    syntax,         // 语法错误（不符合文法）
    semantic,       // 语义错误（类型不匹配、未定义变量）
    runtime,        // 运行时错误（仅 REPL/执行时）
    config,         // 配置错误
};

// ------------------------------------------------------------
// 位置信息（文件名 + 行号 + 列号）
// ------------------------------------------------------------
pub const Location = struct {
    file: []const u8 = "<repl>",  // 文件名，REPL 模式下特殊标记
    line: u32 = 0,
    column: u32 = 0,

    pub fn format(self: Location, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        try writer.print("{}:{}:{}", .{ self.file, self.line, self.column });
    }
};

// JavixError 的 print 方法
pub const JavixError = struct {
    kind: ErrorKind,
    loc: Location,
    msg: []const u8,

    // 打印错误到 stderr
    pub fn print(self: JavixError, io: std.Io) void {
        var buf: [1024]u8 = undefined;
        var err_writer = std.Io.File.Writer.init(std.Io.File.stderr(), io, &buf);
        const kind_str = switch (self.kind) {
            .generic => "ERROR",
            .io => "IO_ERROR",
            .lexer => "LEXER_ERROR",
            .syntax => "SYNTAX_ERROR",
            .semantic => "SEMANTIC_ERROR",
            .runtime => "RUNTIME_ERROR",
            .config => "CONFIG_ERROR",
        };
        err_writer.interface.writeAll("[") catch return;
        err_writer.interface.writeAll(kind_str) catch return;
        err_writer.interface.writeAll("] ") catch return;
        // 简化位置打印
        err_writer.interface.writeAll(self.msg) catch return;
        err_writer.interface.writeAll("\n") catch return;
        err_writer.interface.flush() catch return;
    }
};

// ------------------------------------------------------------
// 便捷错误构造器
// ------------------------------------------------------------
pub fn err(kind: ErrorKind, loc: Location, msg: []const u8) JavixError {
    return JavixError{ .kind = kind, .loc = loc, .msg = msg };
}

pub fn genericErr(msg: []const u8) JavixError {
    return err(.generic, .{ .file = "<internal>", .line = 0, .column = 0 }, msg);
}

// ==================================================================
// 单元测试
// ==================================================================

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expect = testing.expect;

test "errors: Location default is repl" {
    const loc = Location{};
    try expectEqualStrings("<repl>", loc.file);
    try expectEqual(@as(u32, 0), loc.line);
    try expectEqual(@as(u32, 0), loc.column);
}

test "errors: err constructs JavixError" {
    const loc = Location{ .file = "test.jx", .line = 10, .column = 5 };
    const e = err(.syntax, loc, "unexpected token");
    try expectEqual(ErrorKind.syntax, e.kind);
    try expectEqual(@as(u32, 10), e.loc.line);
    try expectEqual(@as(u32, 5), e.loc.column);
    try expectEqualStrings("unexpected token", e.msg);
}

test "errors: genericErr uses internal location" {
    const e = genericErr("something wrong");
    try expectEqual(ErrorKind.generic, e.kind);
    try expectEqualStrings("<internal>", e.loc.file);
    try expectEqualStrings("something wrong", e.msg);
}

test "errors: all ErrorKind values" {
    // 确保所有错误类型都可以构造
    const kinds = [_]ErrorKind{ .generic, .io, .lexer, .syntax, .semantic, .runtime, .config };
    for (kinds) |k| {
        const e = err(k, Location{}, "test");
        try expectEqual(k, e.kind);
    }
}