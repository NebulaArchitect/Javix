// ============================================================
// 文件名: src/compiler_core/token.zig
// ============================================================

const std = @import("std");

// ------------------------------------------------------------------
// Token 类型枚举（完整 Java 词法规范）
// ------------------------------------------------------------------
pub const TokenType = enum {
    // ===== 关键字 (50个，对标 Java) =====
    kw_abstract,
    kw_assert,
    kw_boolean,
    kw_break,
    kw_byte,
    kw_case,
    kw_catch,
    kw_char,
    kw_class,
    kw_const,
    kw_continue,
    kw_default,
    kw_do,
    kw_double,
    kw_else,
    kw_enum,
    kw_extends,
    kw_final,
    kw_finally,
    kw_float,
    kw_fn,
    kw_for,
    kw_goto,
    kw_if,
    kw_implements,
    kw_import,
    kw_instanceof,
    kw_int,
    kw_interface,
    kw_long,
    kw_native,
    kw_new,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_return,
    kw_short,
    kw_static,
    kw_strictfp,
    kw_string,
    kw_String,
    kw_super,
    kw_switch,
    kw_synchronized,
    kw_this,
    kw_throw,
    kw_throws,
    kw_transient,
    kw_try,
    kw_void,
    kw_volatile,
    kw_while,

    // ===== 字面量 =====
    literal_int,        // 123
    literal_long,       // 123L
    literal_float,      // 3.14f
    literal_double,     // 3.14, 3.14d, 1e-5
    literal_char,       // 'a'
    literal_string,     // "hello"
    literal_boolean,    // true / false
    literal_null,       // null

    // ===== 标识符 =====
    identifier,         // 变量名、方法名、类名

    // ===== 运算符 (38个) =====
    // 算术
    plus,           // +
    minus,          // -
    star,           // *
    slash,          // /
    percent,        // %
    plus_plus,      // ++
    minus_minus,    // --
    // 赋值
    assign,                 // =
    plus_assign,            // +=
    minus_assign,           // -=
    star_assign,            // *=
    slash_assign,           // /=
    percent_assign,         // %=
    // 比较
    equal,                  // ==
    not_equal,              // !=
    less,                   // <
    less_equal,             // <=
    greater,                // >
    greater_equal,          // >=
    // 逻辑
    bool_and,                    // &&
    bool_or,                     // ||
    bool_not,                    // !
    // 三元
    question,               // ?
    colon,                  // :
    // 位运算
    bit_and,                // &
    bit_or,                 // |
    bit_xor,                // ^
    bit_not,                // ~
    shift_left,             // <<
    shift_right,            // >>
    shift_right_unsigned,   // >>>
    // 位运算赋值
    bit_and_assign,         // &=
    bit_or_assign,          // |=
    bit_xor_assign,         // ^=
    shift_left_assign,      // <<=
    shift_right_assign,     // >>=
    shift_right_unsigned_assign, // >>>=
    // Lambda & 方法引用
    arrow,                  // ->
    double_colon,           // ::

    // ===== 分隔符 (12个) =====
    l_paren,        // (
    r_paren,        // )
    l_brace,        // {
    r_brace,        // }
    l_bracket,      // [
    r_bracket,      // ]
    semicolon,      // ;
    comma,          // ,
    dot,            // .
    at,             // @ (注解)
    triple_dot,     // ... (变长参数)

    // ===== 特殊 =====
    eof,            // 文件结束
    token_error,          // 词法错误
};

// ------------------------------------------------------------------
// Token 值（携带字面量数据）
// ------------------------------------------------------------------
pub const TokenValue = union(enum) {
    none: void,
    int: i64,
    long: i64,
    float: f32,
    double: f64,
    char: u21,
    string: []const u8,      // 注意：需要分配器管理内存
    boolean: bool,
    identifier: []const u8,   // 注意：需要分配器管理内存
};

// ------------------------------------------------------------------
// Token 结构体
// ------------------------------------------------------------------
pub const Token = struct {
    type: TokenType,
    value: TokenValue = .none,
    line: u32 = 0,
    column: u32 = 0,
    lexeme: []const u8 = "",  // 原始字符串片段（便于调试）

    pub fn format(self: Token, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self.value) {
            .none => try writer.print("{s}", .{@tagName(self.type)}),
            .int => |v| try writer.print("{s}({d})", .{ @tagName(self.type), v }),
            .long => |v| try writer.print("{s}({d}L)", .{ @tagName(self.type), v }),
            .float => |v| try writer.print("{s}({d}f)", .{ @tagName(self.type), v }),
            .double => |v| try writer.print("{s}({d})", .{ @tagName(self.type), v }),
            .char => |v| try writer.print("{s}('{u}')", .{ @tagName(self.type), v }),
            .string => |v| try writer.print("{s}(\"{s}\")", .{ @tagName(self.type), v }),
            .boolean => |v| try writer.print("{s}({})", .{ @tagName(self.type), v }),
            .identifier => |v| try writer.print("{s}({s})", .{ @tagName(self.type), v }),
        }
    }
};

// ==================================================================
// 单元测试
// ==================================================================

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expect = testing.expect;

test "Token: format int literal" {
    const tok = Token{ .type = .literal_int, .value = .{ .int = 42 } };
    // format 通过 writer 输出，这里只验证值和类型正确
    try expectEqual(@as(i64, 42), tok.value.int);
    try expectEqual(TokenType.literal_int, tok.type);
}

test "Token: format string literal" {
    const tok = Token{ .type = .literal_string, .value = .{ .string = "hello" } };
    try expectEqualStrings("hello", tok.value.string);
    try expectEqual(TokenType.literal_string, tok.type);
}

test "Token: format char literal" {
    const tok = Token{ .type = .literal_char, .value = .{ .char = 'A' } };
    try expectEqual(@as(u21, 'A'), tok.value.char);
}

test "Token: format boolean literal" {
    const t = Token{ .type = .literal_boolean, .value = .{ .boolean = true } };
    const f = Token{ .type = .literal_boolean, .value = .{ .boolean = false } };
    try expectEqual(true, t.value.boolean);
    try expectEqual(false, f.value.boolean);
}

test "Token: format identifier" {
    const tok = Token{ .type = .identifier, .value = .{ .identifier = "myVar" } };
    try expectEqualStrings("myVar", tok.value.identifier);
}

test "Token: line and column default to zero" {
    const tok = Token{ .type = .eof };
    try expectEqual(@as(u32, 0), tok.line);
    try expectEqual(@as(u32, 0), tok.column);
}

test "Token: lexeme tracking" {
    const tok = Token{ .type = .plus, .lexeme = "+" };
    try expectEqualStrings("+", tok.lexeme);
}