// ============================================================
// 文件名: src/compiler_core/lexer.zig
// ============================================================

const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const TokenValue = @import("token.zig").TokenValue;

pub const Lexer = struct {
    source: []const u8,
    index: usize = 0,
    line: u32 = 1,
    column: u32 = 1,
    allocator: std.mem.Allocator,

    // ------------------------------------------------------------------
    // 初始化
    // ------------------------------------------------------------------
    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return Lexer{
            .allocator = allocator,
            .source = source,
            .index = 0,
            .line = 1,
            .column = 1,
        };
    }

    // ------------------------------------------------------------------
    // 获取下一个 Token
    // ------------------------------------------------------------------
    pub fn nextToken(self: *Lexer) !Token {
        self.skipWhitespace();
        if (self.isAtEnd()) {
            return self.makeToken(TokenType.eof, .none, "");
        }

        const start = self.index;
        const c = self.source[self.index];
        const start_line = self.line;
        const start_col = self.column;

        // 数字
        if (isDigit(c)) {
            return self.readNumber(start, start_line, start_col);
        }

        // 标识符或关键字
        if (isAlpha(c)) {
            return self.readIdentifierOrKeyword(start, start_line, start_col);
        }

        // 字符串
        if (c == '"') {
            return self.readString(start, start_line, start_col);
        }

        // 字符
        if (c == '\'') {
            return self.readChar(start, start_line, start_col);
        }

        // 运算符和分隔符（多字符检测）
        if (c == '=') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '=') {
                self.advance();
                return self.makeToken(TokenType.equal, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.assign, .none, self.source[start..self.index]);
        }

        if (c == '!') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '=') {
                self.advance();
                return self.makeToken(TokenType.not_equal, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.bool_not, .none, self.source[start..self.index]);
        }

        if (c == '&') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '&') {
                self.advance();
                return self.makeToken(TokenType.bool_and, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.bit_and, .none, self.source[start..self.index]);
        }

        if (c == '|') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '|') {
                self.advance();
                return self.makeToken(TokenType.bool_or, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.bit_or, .none, self.source[start..self.index]);
        }

        if (c == '+') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '+') {
                self.advance();
                return self.makeToken(TokenType.plus_plus, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.plus, .none, self.source[start..self.index]);
        }

        if (c == '-') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '-') {
                self.advance();
                return self.makeToken(TokenType.minus_minus, .none, self.source[start..self.index]);
            }
            if (!self.isAtEnd() and self.source[self.index] == '>') {
                self.advance();
                return self.makeToken(TokenType.arrow, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.minus, .none, self.source[start..self.index]);
        }

        if (c == '*') {
            self.advance();
            return self.makeToken(TokenType.star, .none, self.source[start..self.index]);
        }

        if (c == '/') {
            self.advance();
            // 注释处理
            if (!self.isAtEnd() and self.source[self.index] == '/') {
                // 单行注释：跳过到行尾
                while (!self.isAtEnd() and self.source[self.index] != '\n') {
                    self.advance();
                }
                return self.nextToken(); // 跳过注释，继续下一个 Token
            }
            if (!self.isAtEnd() and self.source[self.index] == '*') {
                // 多行注释
                self.advance();
                while (!self.isAtEnd()) {
                    if (self.source[self.index] == '*' and !self.isAtEnd() and self.source[self.index + 1] == '/') {
                        self.advance();
                        self.advance();
                        break;
                    }
                    if (self.source[self.index] == '\n') {
                        self.line += 1;
                        self.column = 1;
                    }
                    self.advance();
                }
                return self.nextToken();
            }
            return self.makeToken(TokenType.slash, .none, self.source[start..self.index]);
        }

        if (c == '%') {
            self.advance();
            return self.makeToken(TokenType.percent, .none, self.source[start..self.index]);
        }

        if (c == '<') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '=') {
                self.advance();
                return self.makeToken(TokenType.less_equal, .none, self.source[start..self.index]);
            }
            if (!self.isAtEnd() and self.source[self.index] == '<') {
                self.advance();
                if (!self.isAtEnd() and self.source[self.index] == '=') {
                    self.advance();
                    return self.makeToken(TokenType.shift_left_assign, .none, self.source[start..self.index]);
                }
                return self.makeToken(TokenType.shift_left, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.less, .none, self.source[start..self.index]);
        }

        if (c == '>') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '=') {
                self.advance();
                return self.makeToken(TokenType.greater_equal, .none, self.source[start..self.index]);
            }
            if (!self.isAtEnd() and self.source[self.index] == '>') {
                self.advance();
                if (!self.isAtEnd() and self.source[self.index] == '>') {
                    self.advance();
                    if (!self.isAtEnd() and self.source[self.index] == '=') {
                        self.advance();
                        return self.makeToken(TokenType.shift_right_unsigned_assign, .none, self.source[start..self.index]);
                    }
                    return self.makeToken(TokenType.shift_right_unsigned, .none, self.source[start..self.index]);
                }
                if (!self.isAtEnd() and self.source[self.index] == '=') {
                    self.advance();
                    return self.makeToken(TokenType.shift_right_assign, .none, self.source[start..self.index]);
                }
                return self.makeToken(TokenType.shift_right, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.greater, .none, self.source[start..self.index]);
        }

        if (c == ':') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == ':') {
                self.advance();
                return self.makeToken(TokenType.double_colon, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.colon, .none, self.source[start..self.index]);
        }

        if (c == '?') {
            self.advance();
            return self.makeToken(TokenType.question, .none, self.source[start..self.index]);
        }

        if (c == '^') {
            self.advance();
            return self.makeToken(TokenType.bit_xor, .none, self.source[start..self.index]);
        }

        if (c == '~') {
            self.advance();
            return self.makeToken(TokenType.bit_not, .none, self.source[start..self.index]);
        }

        if (c == '(') {
            self.advance();
            return self.makeToken(TokenType.l_paren, .none, self.source[start..self.index]);
        }
        if (c == ')') {
            self.advance();
            return self.makeToken(TokenType.r_paren, .none, self.source[start..self.index]);
        }
        if (c == '{') {
            self.advance();
            return self.makeToken(TokenType.l_brace, .none, self.source[start..self.index]);
        }
        if (c == '}') {
            self.advance();
            return self.makeToken(TokenType.r_brace, .none, self.source[start..self.index]);
        }
        if (c == '[') {
            self.advance();
            return self.makeToken(TokenType.l_bracket, .none, self.source[start..self.index]);
        }
        if (c == ']') {
            self.advance();
            return self.makeToken(TokenType.r_bracket, .none, self.source[start..self.index]);
        }
        if (c == ';') {
            self.advance();
            return self.makeToken(TokenType.semicolon, .none, self.source[start..self.index]);
        }
        if (c == ',') {
            self.advance();
            return self.makeToken(TokenType.comma, .none, self.source[start..self.index]);
        }
        if (c == '.') {
            self.advance();
            if (!self.isAtEnd() and self.source[self.index] == '.' and !self.isAtEnd() and self.source[self.index + 1] == '.') {
                self.advance();
                self.advance();
                return self.makeToken(TokenType.triple_dot, .none, self.source[start..self.index]);
            }
            return self.makeToken(TokenType.dot, .none, self.source[start..self.index]);
        }
        if (c == '@') {
            self.advance();
            return self.makeToken(TokenType.at, .none, self.source[start..self.index]);
        }

        // 非法字符
        self.advance();
        return self.makeToken(TokenType.token_error, .none, self.source[start..self.index]);
    }

    // ------------------------------------------------------------------
    // 读取数字（整数和浮点）
    // 支持: int, long(后缀L/l), float(后缀f/F), double(后缀d/D或无后缀)
    // TODO: 十六进制 0x, 二进制 0b, 八进制 0, 科学计数法
    // ------------------------------------------------------------------
    fn readNumber(self: *Lexer, start: usize, start_line: u32, start_col: u32) !Token {
        _ = start_line;
        _ = start_col;
        while (!self.isAtEnd() and isDigit(self.source[self.index])) {
            self.advance();
        }
        // 检查浮点数
        if (!self.isAtEnd() and self.source[self.index] == '.') {
            self.advance();
            while (!self.isAtEnd() and isDigit(self.source[self.index])) {
                self.advance();
            }
            // 检查后缀 f/F → float, d/D → double
            if (!self.isAtEnd()) {
                const suffix = self.source[self.index];
                if (suffix == 'f' or suffix == 'F') {
                    self.advance();
                    const num_str = self.source[start..self.index];
                    const num_no_suffix = num_str[0 .. num_str.len - 1];
                    const value = try std.fmt.parseFloat(f32, num_no_suffix);
                    return self.makeToken(TokenType.literal_float, .{ .float = value }, num_str);
                }
                if (suffix == 'd' or suffix == 'D') {
                    self.advance();
                    const num_str = self.source[start..self.index];
                    const num_no_suffix = num_str[0 .. num_str.len - 1];
                    const value = try std.fmt.parseFloat(f64, num_no_suffix);
                    return self.makeToken(TokenType.literal_double, .{ .double = value }, num_str);
                }
            }
            const num_str = self.source[start..self.index];
            const value = try std.fmt.parseFloat(f64, num_str);
            return self.makeToken(TokenType.literal_double, .{ .double = value }, num_str);
        }
        // 整数：检查 L/l 后缀 → long
        if (!self.isAtEnd()) {
            const suffix = self.source[self.index];
            if (suffix == 'L' or suffix == 'l') {
                self.advance();
                const num_str = self.source[start..self.index];
                const num_no_suffix = num_str[0 .. num_str.len - 1];
                const value = try std.fmt.parseInt(i64, num_no_suffix, 10);
                return self.makeToken(TokenType.literal_long, .{ .long = value }, num_str);
            }
        }
        const num_str = self.source[start..self.index];
        const value = try std.fmt.parseInt(i64, num_str, 10);
        return self.makeToken(TokenType.literal_int, .{ .int = value }, num_str);
    }

    // ------------------------------------------------------------------
    // 读取字符串
    // 支持转义序列: \\ \n \t \"
    // ------------------------------------------------------------------
    fn readString(self: *Lexer, start: usize, start_line: u32, start_col: u32) !Token {
        _ = start_line;
        _ = start_col;
        self.advance(); // 跳过开始的双引号

        // 用 ArrayList 构建结果（处理转义后可能变短）
        var result: std.ArrayListUnmanaged(u8) = .empty;
        defer result.deinit(self.allocator);

        while (!self.isAtEnd() and self.source[self.index] != '"') {
            if (self.source[self.index] == '\\') {
                self.advance(); // 跳过反斜杠
                if (self.isAtEnd()) {
                    return self.makeToken(TokenType.token_error, .none, "Unclosed string escape");
                }
                const escaped = self.source[self.index];
                const resolved: u8 = switch (escaped) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    '\\' => '\\',
                    '"' => '"',
                    else => escaped, // 未知转义保留原字符
                };
                try result.append(self.allocator, resolved);
                self.advance();
            } else if (self.source[self.index] == '\n') {
                self.line += 1;
                self.column = 1;
                try result.append(self.allocator, '\n');
                self.advance();
            } else {
                try result.append(self.allocator, self.source[self.index]);
                self.advance();
            }
        }
        if (self.isAtEnd()) {
            return self.makeToken(TokenType.token_error, .none, "Unclosed string literal");
        }
        self.advance(); // 跳过结束的双引号
        const str_dup = try result.toOwnedSlice(self.allocator);
        return self.makeToken(TokenType.literal_string, .{ .string = str_dup }, self.source[start..self.index]);
    }

    // ------------------------------------------------------------------
    // 读取字符字面量
    // TODO: 转义序列
    // ------------------------------------------------------------------
    fn readChar(self: *Lexer, start: usize, start_line: u32, start_col: u32) !Token {
        _ = start_line;
        _ = start_col;
        self.advance(); // 跳过开始的单引号
        if (self.isAtEnd()) {
            return self.makeToken(TokenType.token_error, .none, "Unclosed char literal");
        }
        const ch = self.source[self.index];
        self.advance();
        if (self.isAtEnd() or self.source[self.index] != '\'') {
            return self.makeToken(TokenType.token_error, .none, "Unclosed char literal");
        }
        self.advance(); // 跳过结束的单引号
        return self.makeToken(TokenType.literal_char, .{ .char = ch }, self.source[start..self.index]);
    }

    // ------------------------------------------------------------------
    // 读取标识符或关键字
    // ------------------------------------------------------------------
    fn readIdentifierOrKeyword(self: *Lexer, start: usize, start_line: u32, start_col: u32) !Token {
        _ = start_line;
        _ = start_col;
        while (!self.isAtEnd() and (self.isAlphaNumeric(self.source[self.index]))) {
            self.advance();
        }
        const text = self.source[start..self.index];
        const token_type = self.keywordType(text);
        if (token_type == TokenType.identifier) {
            const ident_dup = try self.allocator.dupe(u8, text);
            return self.makeToken(token_type, .{ .identifier = ident_dup }, text);
        }
        if (token_type == TokenType.literal_boolean) {
            const bool_val = std.mem.eql(u8, text, "true");
            return self.makeToken(token_type, .{ .boolean = bool_val }, text);
        }
        return self.makeToken(token_type, .none, text);
    }

    // ------------------------------------------------------------------
    // 关键字映射
    // ------------------------------------------------------------------
    fn keywordType(self: *Lexer, text: []const u8) TokenType {
        _ = self;
        const kw_map = std.StaticStringMap(TokenType).initComptime(.{
            .{ "abstract", .kw_abstract },
            .{ "assert", .kw_assert },
            .{ "boolean", .kw_boolean },
            .{ "break", .kw_break },
            .{ "byte", .kw_byte },
            .{ "case", .kw_case },
            .{ "catch", .kw_catch },
            .{ "char", .kw_char },
            .{ "class", .kw_class },
            .{ "const", .kw_const },
            .{ "continue", .kw_continue },
            .{ "default", .kw_default },
            .{ "do", .kw_do },
            .{ "double", .kw_double },
            .{ "else", .kw_else },
            .{ "enum", .kw_enum },
            .{ "extends", .kw_extends },
            .{ "final", .kw_final },
            .{ "finally", .kw_finally },
            .{ "float", .kw_float },
            .{ "fn", .kw_fn },
            .{ "for", .kw_for },
            .{ "goto", .kw_goto },
            .{ "if", .kw_if },
            .{ "implements", .kw_implements },
            .{ "import", .kw_import },
            .{ "instanceof", .kw_instanceof },
            .{ "int", .kw_int },
            .{ "interface", .kw_interface },
            .{ "long", .kw_long },
            .{ "native", .kw_native },
            .{ "new", .kw_new },
            .{ "package", .kw_package },
            .{ "private", .kw_private },
            .{ "protected", .kw_protected },
            .{ "public", .kw_public },
            .{ "return", .kw_return },
            .{ "short", .kw_short },
            .{ "static", .kw_static },
            .{ "strictfp", .kw_strictfp },
            .{ "string", .kw_string },
            .{ "String", .kw_String },
            .{ "super", .kw_super },
            .{ "switch", .kw_switch },
            .{ "synchronized", .kw_synchronized },
            .{ "this", .kw_this },
            .{ "throw", .kw_throw },
            .{ "throws", .kw_throws },
            .{ "transient", .kw_transient },
            .{ "try", .kw_try },
            .{ "void", .kw_void },
            .{ "volatile", .kw_volatile },
            .{ "while", .kw_while },
            .{ "true", .literal_boolean },
            .{ "false", .literal_boolean },
            .{ "null", .literal_null },
        });
        return kw_map.get(text) orelse TokenType.identifier;
    }

    // ------------------------------------------------------------------
    // 辅助函数
    // ------------------------------------------------------------------
    fn advance(self: *Lexer) void {
        if (self.source[self.index] == '\n') {
            self.line += 1;
            self.column = 1;
        } else {
            self.column += 1;
        }
        self.index += 1;
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.index >= self.source.len;
    }

    fn isDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }

    fn isAlpha(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
    }

    fn isAlphaNumeric(self: *Lexer, c: u8) bool {
        _ = self;
        return isDigit(c) or isAlpha(c);
    }

    fn skipWhitespace(self: *Lexer) void {
        while (!self.isAtEnd()) {
            const c = self.source[self.index];
            if (c == ' ' or c == '\r' or c == '\t') {
                self.advance();
            } else if (c == '\n') {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn makeToken(self: *Lexer, tok_type: TokenType, value: TokenValue, lexeme: []const u8) Token {
        return Token{
            .type = tok_type,
            .value = value,
            .line = self.line,
            .column = self.column,
            .lexeme = lexeme,
        };
    }
};

// ==================================================================
// 单元测试
// ==================================================================

const testing = std.testing;
const expect = testing.expect;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;

/// 释放 token 中分配的堆内存
fn freeTokenValue(token: *const Token, allocator: std.mem.Allocator) void {
    switch (token.value) {
        .string => |s| allocator.free(s),
        .identifier => |s| allocator.free(s),
        else => {},
    }
}

// ---- 分隔符 ----

test "lexer: empty source returns EOF" {
    var lex = Lexer.init(testing.allocator, "");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.eof, tok.type);
}

test "lexer: separators" {
    var lex = Lexer.init(testing.allocator, "(){}[];,.");
    const expected = [_]TokenType{ .l_paren, .r_paren, .l_brace, .r_brace, .l_bracket, .r_bracket, .semicolon, .comma, .dot };
    for (expected) |exp| {
        const tok = try lex.nextToken();
        try expectEqual(exp, tok.type);
    }
    try expectEqual(TokenType.eof, (try lex.nextToken()).type);
}

test "lexer: triple dot" {
    var lex = Lexer.init(testing.allocator, "...");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.triple_dot, tok.type);
}

test "lexer: double colon" {
    var lex = Lexer.init(testing.allocator, "::");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.double_colon, tok.type);
}

test "lexer: arrow" {
    var lex = Lexer.init(testing.allocator, "->");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.arrow, tok.type);
}

test "lexer: at sign" {
    var lex = Lexer.init(testing.allocator, "@");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.at, tok.type);
}

// ---- 算术运算符 ----

test "lexer: arithmetic operators" {
    var lex = Lexer.init(testing.allocator, "+ - * / %");
    const expected = [_]TokenType{ .plus, .minus, .star, .slash, .percent };
    for (expected) |exp| {
        const tok = try lex.nextToken();
        try expectEqual(exp, tok.type);
    }
}

test "lexer: increment and decrement" {
    var lex = Lexer.init(testing.allocator, "++ --");
    try expectEqual(TokenType.plus_plus, (try lex.nextToken()).type);
    try expectEqual(TokenType.minus_minus, (try lex.nextToken()).type);
}

// ---- 赋值运算符 ----

test "lexer: assign vs equal" {
    var lex = Lexer.init(testing.allocator, "= ==");
    try expectEqual(TokenType.assign, (try lex.nextToken()).type);
    try expectEqual(TokenType.equal, (try lex.nextToken()).type);
}

test "lexer: not equal and bool not" {
    var lex = Lexer.init(testing.allocator, "!= !");
    try expectEqual(TokenType.not_equal, (try lex.nextToken()).type);
    try expectEqual(TokenType.bool_not, (try lex.nextToken()).type);
}

test "lexer: compound assignment operators" {
    var lex = Lexer.init(testing.allocator, "+= -= *= /= %= &= |= ^=");
    const expected = [_]TokenType{
        .plus_assign, .minus_assign, .star_assign, .slash_assign,
        .percent_assign, .bit_and_assign, .bit_or_assign, .bit_xor_assign,
    };
    for (expected) |exp| {
        try expectEqual(exp, (try lex.nextToken()).type);
    }
}

// ---- 比较和逻辑运算符 ----

test "lexer: comparison operators" {
    var lex = Lexer.init(testing.allocator, "< > <= >=");
    try expectEqual(TokenType.less, (try lex.nextToken()).type);
    try expectEqual(TokenType.greater, (try lex.nextToken()).type);
    try expectEqual(TokenType.less_equal, (try lex.nextToken()).type);
    try expectEqual(TokenType.greater_equal, (try lex.nextToken()).type);
}

test "lexer: logical operators" {
    var lex = Lexer.init(testing.allocator, "&& ||");
    try expectEqual(TokenType.bool_and, (try lex.nextToken()).type);
    try expectEqual(TokenType.bool_or, (try lex.nextToken()).type);
}

// ---- 位运算符 ----

test "lexer: bitwise operators" {
    var lex = Lexer.init(testing.allocator, "& | ^ ~");
    try expectEqual(TokenType.bit_and, (try lex.nextToken()).type);
    try expectEqual(TokenType.bit_or, (try lex.nextToken()).type);
    try expectEqual(TokenType.bit_xor, (try lex.nextToken()).type);
    try expectEqual(TokenType.bit_not, (try lex.nextToken()).type);
}

test "lexer: shift operators" {
    var lex = Lexer.init(testing.allocator, "<< >> >>>");
    try expectEqual(TokenType.shift_left, (try lex.nextToken()).type);
    try expectEqual(TokenType.shift_right, (try lex.nextToken()).type);
    try expectEqual(TokenType.shift_right_unsigned, (try lex.nextToken()).type);
}

test "lexer: shift assign operators" {
    var lex = Lexer.init(testing.allocator, "<<= >>= >>>=");
    try expectEqual(TokenType.shift_left_assign, (try lex.nextToken()).type);
    try expectEqual(TokenType.shift_right_assign, (try lex.nextToken()).type);
    try expectEqual(TokenType.shift_right_unsigned_assign, (try lex.nextToken()).type);
}

test "lexer: ternary operators" {
    var lex = Lexer.init(testing.allocator, "? :");
    try expectEqual(TokenType.question, (try lex.nextToken()).type);
    try expectEqual(TokenType.colon, (try lex.nextToken()).type);
}

// ---- 字面量 ----

test "lexer: integer literal" {
    var lex = Lexer.init(testing.allocator, "42 0 999");
    try expectEqual(@as(i64, 42), (try lex.nextToken()).value.int);
    try expectEqual(@as(i64, 0), (try lex.nextToken()).value.int);
    try expectEqual(@as(i64, 999), (try lex.nextToken()).value.int);
}

test "lexer: long literal" {
    var lex = Lexer.init(testing.allocator, "42L 0l");
    try expectEqual(@as(i64, 42), (try lex.nextToken()).value.long);
    try expectEqual(@as(i64, 0), (try lex.nextToken()).value.long);
}

test "lexer: float literal" {
    var lex = Lexer.init(testing.allocator, "3.14f 2.5F");
    const f1 = (try lex.nextToken()).value.float;
    const f2 = (try lex.nextToken()).value.float;
    try expect(@abs(f1 - 3.14) < 0.001);
    try expect(@abs(f2 - 2.5) < 0.001);
}

test "lexer: double literal" {
    var lex = Lexer.init(testing.allocator, "3.14 1.5d 2.0D");
    const d1 = (try lex.nextToken()).value.double;
    const d2 = (try lex.nextToken()).value.double;
    const d3 = (try lex.nextToken()).value.double;
    try expect(@abs(d1 - 3.14) < 0.001);
    try expect(@abs(d2 - 1.5) < 0.001);
    try expect(@abs(d3 - 2.0) < 0.001);
}

test "lexer: boolean and null literals" {
    var lex = Lexer.init(testing.allocator, "true false null");
    try expectEqual(true, (try lex.nextToken()).value.boolean);
    try expectEqual(false, (try lex.nextToken()).value.boolean);
    try expectEqual(TokenType.literal_null, (try lex.nextToken()).type);
}

test "lexer: char literal" {
    var lex = Lexer.init(testing.allocator, "'a' 'Z' '9'");
    try expectEqual(@as(u21, 'a'), (try lex.nextToken()).value.char);
    try expectEqual(@as(u21, 'Z'), (try lex.nextToken()).value.char);
    try expectEqual(@as(u21, '9'), (try lex.nextToken()).value.char);
}

test "lexer: string literal basic" {
    var lex = Lexer.init(testing.allocator, "\"hello\" \"world\"");
    const t1 = try lex.nextToken();
    defer testing.allocator.free(t1.value.string);
    try expectEqualStrings("hello", t1.value.string);

    const t2 = try lex.nextToken();
    defer testing.allocator.free(t2.value.string);
    try expectEqualStrings("world", t2.value.string);
}

test "lexer: string escape sequences" {
    var lex = Lexer.init(testing.allocator, "\"a\\nb\\tc\\\\d\\\"e\"");
    const tok = try lex.nextToken();
    defer testing.allocator.free(tok.value.string);
    // \n → newline, \t → tab, \\ → \, \" → "
    try expectEqualStrings("a\nb\tc\\d\"e", tok.value.string);
}

// ---- 关键字 ----

test "lexer: keywords" {
    var lex = Lexer.init(testing.allocator, "class extends implements interface abstract enum package import fn return if else while for do switch case default break continue new this super public private protected static final void");
    const expected = [_]TokenType{
        .kw_class, .kw_extends, .kw_implements, .kw_interface, .kw_abstract, .kw_enum,
        .kw_package, .kw_import, .kw_fn, .kw_return, .kw_if, .kw_else, .kw_while,
        .kw_for, .kw_do, .kw_switch, .kw_case, .kw_default, .kw_break, .kw_continue,
        .kw_new, .kw_this, .kw_super, .kw_public, .kw_private, .kw_protected,
        .kw_static, .kw_final, .kw_void,
    };
    for (expected) |exp| {
        try expectEqual(exp, (try lex.nextToken()).type);
    }
}

// ---- 标识符 ----

test "lexer: identifiers" {
    var lex = Lexer.init(testing.allocator, "foo bar123 _hidden $money");
    const expected_names = [_][]const u8{ "foo", "bar123", "_hidden", "$money" };
    for (expected_names) |name| {
        const tok = try lex.nextToken();
        defer testing.allocator.free(tok.value.identifier);
        try expectEqualStrings(name, tok.value.identifier);
    }
}

// ---- 注释 ----

test "lexer: single line comment skipped" {
    var lex = Lexer.init(testing.allocator, "// this is a comment\n42");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.literal_int, tok.type);
    try expectEqual(@as(i64, 42), tok.value.int);
}

test "lexer: multi line comment skipped" {
    var lex = Lexer.init(testing.allocator, "/* this is a\nmulti-line comment */ 42");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.literal_int, tok.type);
    try expectEqual(@as(i64, 42), tok.value.int);
}

test "lexer: comment at end of line" {
    var lex = Lexer.init(testing.allocator, "42 // comment");
    try expectEqual(@as(i64, 42), (try lex.nextToken()).value.int);
    try expectEqual(TokenType.eof, (try lex.nextToken()).type);
}

// ---- 行号/列号 ----

test "lexer: line and column tracking" {
    var lex = Lexer.init(testing.allocator, "x\ny\nz");
    const t1 = try lex.nextToken();
    defer testing.allocator.free(t1.value.identifier);
    try expectEqual(@as(u32, 1), t1.line);
    try expectEqual(@as(u32, 1), t1.column);

    const t2 = try lex.nextToken();
    defer testing.allocator.free(t2.value.identifier);
    try expectEqual(@as(u32, 2), t2.line);
    try expectEqual(@as(u32, 1), t2.column);

    const t3 = try lex.nextToken();
    defer testing.allocator.free(t3.value.identifier);
    try expectEqual(@as(u32, 3), t3.line);
    try expectEqual(@as(u32, 1), t3.column);
}

// ---- 错误 token ----

test "lexer: unclosed string returns error token" {
    var lex = Lexer.init(testing.allocator, "\"unclosed");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.token_error, tok.type);
}

test "lexer: unclosed char returns error token" {
    var lex = Lexer.init(testing.allocator, "'x");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.token_error, tok.type);
}

test "lexer: illegal character returns error token" {
    var lex = Lexer.init(testing.allocator, "#");
    const tok = try lex.nextToken();
    try expectEqual(TokenType.token_error, tok.type);
}

// ---- 综合场景 ----

test "lexer: typical variable declaration" {
    var lex = Lexer.init(testing.allocator, "int x = 42;");
    try expectEqual(TokenType.kw_int, (try lex.nextToken()).type);
    const ident = try lex.nextToken();
    defer testing.allocator.free(ident.value.identifier);
    try expectEqualStrings("x", ident.value.identifier);
    try expectEqual(TokenType.assign, (try lex.nextToken()).type);
    try expectEqual(@as(i64, 42), (try lex.nextToken()).value.int);
    try expectEqual(TokenType.semicolon, (try lex.nextToken()).type);
}

test "lexer: simple function definition" {
    var lex = Lexer.init(testing.allocator, "fn add(a: int, b: int) { return a + b; }");
    try expectEqual(TokenType.kw_fn, (try lex.nextToken()).type);
    const fn_name = try lex.nextToken();
    defer testing.allocator.free(fn_name.value.identifier);
    try expectEqualStrings("add", fn_name.value.identifier);
    try expectEqual(TokenType.l_paren, (try lex.nextToken()).type);
    const p1 = try lex.nextToken();
    defer testing.allocator.free(p1.value.identifier);
    try expectEqualStrings("a", p1.value.identifier);
    try expectEqual(TokenType.colon, (try lex.nextToken()).type);
    try expectEqual(TokenType.kw_int, (try lex.nextToken()).type);
    try expectEqual(TokenType.comma, (try lex.nextToken()).type);
    // b: int
    const p2 = try lex.nextToken();
    defer testing.allocator.free(p2.value.identifier);
    try expectEqualStrings("b", p2.value.identifier);
    try expectEqual(TokenType.colon, (try lex.nextToken()).type);
    try expectEqual(TokenType.kw_int, (try lex.nextToken()).type);
    try expectEqual(TokenType.r_paren, (try lex.nextToken()).type);
    try expectEqual(TokenType.l_brace, (try lex.nextToken()).type);
    try expectEqual(TokenType.kw_return, (try lex.nextToken()).type);
    const ret_a = try lex.nextToken();
    defer testing.allocator.free(ret_a.value.identifier);
    try expectEqualStrings("a", ret_a.value.identifier);
    try expectEqual(TokenType.plus, (try lex.nextToken()).type);
    const ret_b = try lex.nextToken();
    defer testing.allocator.free(ret_b.value.identifier);
    try expectEqualStrings("b", ret_b.value.identifier);
    try expectEqual(TokenType.semicolon, (try lex.nextToken()).type);
    try expectEqual(TokenType.r_brace, (try lex.nextToken()).type);
}