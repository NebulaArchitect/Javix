// ============================================================
// 文件名: src/compiler_core/parser.zig
// ============================================================

const std = @import("std");
const Token = @import("token.zig").Token;
const TokenType = @import("token.zig").TokenType;
const Node = @import("ast.zig").Node;
const Op = @import("ast.zig").Op;
const VarType = @import("ast.zig").VarType;
const SymbolTable = @import("ast.zig").SymbolTable;
const Param = @import("ast.zig").Param;
const Field = @import("ast.zig").Field;
const FnSig = @import("ast.zig").FnSig;
const Modifiers = @import("ast.zig").Modifiers;
const SwitchCase = @import("ast.zig").SwitchCase;

pub const ParseError = error{OutOfMemory};

pub const Parser = struct {
    tokens: []const Token,
    index: usize,
    allocator: std.mem.Allocator,
    sym_table: *SymbolTable, // 符号表指针
    last_class_name: ?[]const u8 = null, // matchVarType 匹配到 Class 时记录类名

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, sym_table: *SymbolTable) Parser {
        return Parser{
            .allocator = allocator,
            .tokens = tokens,
            .index = 0,
            .sym_table = sym_table,
        };
    }

    // 语句解析入口
    pub fn parseStatement(self: *Parser) ParseError !*Node {
        // 解析修饰符（class/方法/字段/变量前可选）
        const modifiers = self.parseModifiers();

        // if 语句
        if (self.match(.kw_if)) {
            return self.parseIf();
        }
        // while 语句
        if (self.match(.kw_while)) {
            return self.parseWhile();
        }
        // for 语句
        if (self.match(.kw_for)) {
            return self.parseFor();
        }
        // do-while 语句
        if (self.match(.kw_do)) {
            return self.parseDoWhile();
        }
        // switch 语句
        if (self.match(.kw_switch)) {
            return self.parseSwitch();
        }
        // enum 定义
        if (self.match(.kw_enum)) {
            return self.parseEnum();
        }
        // interface 定义
        if (self.match(.kw_interface)) {
            return self.parseInterface();
        }
        // package 声明
        if (self.match(.kw_package)) {
            return self.parsePackage();
        }

        // 函数定义: fn add(a: int, b: int) -> int { ... }
        if (self.match(.kw_fn)) {
            return self.parseFnDef(modifiers);
        }

        // import 语句: import "other.jx";
        if (self.match(.kw_import)) {
            const path_tok = try self.consume(.literal_string, "Expected string path after 'import'");
            const path = try self.allocator.dupe(u8, path_tok.value.string);
            _ = try self.consume(.semicolon, "Expected ';' after import");
            const node = try self.allocator.create(Node);
            node.* = .{ .import_stmt = path };
            return node;
        }

        // class 定义: class Point { ... }
        if (self.match(.kw_class)) {
            return self.parseClassDef(modifiers);
        }

        // return 语句
        if (self.match(.kw_return)) {
            return self.parseReturn();
        }

        // 变量声明: int x = 1; 或 int[] arr = new int[5];
        if (self.matchVarType()) |var_type| {
            return self.parseVarDecl(var_type, modifiers);
        }

        // new 表达式: new int[5]
        if (self.match(.kw_new)) {
            return self.parseNewStmt();
        }

        // 代码块: { ... }
        if (self.match(.l_brace)) {
            return self.parseBlock();
        }

        // 赋值或表达式: x = 1; 或 1 + 2;
        return self.parseExprOrAssign();
    }

    // ========== 变量声明 ==========
    fn matchVarType(self: *Parser) ?VarType {
        const base: VarType = switch (self.peek().type) {
            .kw_int => blk: { _ = self.advance(); break :blk .Int; },
            .kw_long => blk: { _ = self.advance(); break :blk .Long; },
            .kw_float => blk: { _ = self.advance(); break :blk .Float; },
            .kw_double => blk: { _ = self.advance(); break :blk .Double; },
            .kw_char => blk: { _ = self.advance(); break :blk .Char; },
            .kw_string, .kw_String => blk: { _ = self.advance(); break :blk .String; },
            .kw_boolean => blk: { _ = self.advance(); break :blk .Boolean; },
            .kw_void => blk: { _ = self.advance(); break :blk .Void; },
            .identifier => blk: {
                const id = self.peek().value.identifier;
                if (self.sym_table.isClass(id)) {
                    _ = self.advance();
                    self.last_class_name = id;
                    break :blk .Class;
                }
                return null;
            },
            else => return null,
        };
        // 检测 [] → 数组类型
        if (!self.isAtEnd() and self.peek().type == .l_bracket and
            self.peekNext().type == .r_bracket)
        {
            _ = self.advance(); // [
            _ = self.advance(); // ]
            return base.toArray();
        }
        return base;
    }

    fn parseFnDef(self: *Parser, modifiers: Modifiers) ParseError !*Node {
        // 函数名
    const name_tok = try self.consume(.identifier, "Expected function name after 'fn'");
        const name = try self.allocator.dupe(u8, name_tok.value.identifier);

        // 参数列表
        _ = try self.consume(.l_paren, "Expected '(' after function name");
        var params: std.ArrayListUnmanaged(Param) = .empty;
        defer params.deinit(self.allocator);

        while (!self.match(.r_paren)) {
            const name_token = try self.consume(.identifier, "Expected parameter name");
            const param_name = try self.allocator.dupe(u8, name_token.value.identifier);

            _ = try self.consume(.colon, "Expected ':' after parameter name");

            const type_token = self.peek();
            const var_type = self.typeFromToken(type_token.type) orelse {
                return self.errorNode("Expected parameter type");
            };
            _ = self.advance();

            try params.append(self.allocator, Param{ .name = param_name, .var_type = var_type });

            if (!self.match(.comma)) {
                _ = try self.consume(.r_paren, "Expected ')' or ',' after parameter");
                break;
            }
        }

        // 返回类型: -> int
    _ = try self.consume(.arrow, "Expected '->' before return type");
        const return_type_tok = self.peek();
        const return_type = self.typeFromToken(return_type_tok.type) orelse {
            return self.errorNode("Expected return type");
        };
        _ = self.advance();

        // 函数体
        _ = try self.consume(.l_brace, "Expected '{' before function body");
        const body = try self.parseBlock();
        // 可选分号（允许 fn ... { } ; 写法）
        _ = self.match(.semicolon);

        // 复制 params 到堆上（供符号表和 AST 使用）
        const params_slice = try params.toOwnedSlice(self.allocator);

        // 注册函数到符号表
        try self.sym_table.defineFn(name, params_slice, return_type);

        const node = try self.allocator.create(Node);
        node.* = .{ .fn_def = .{
            .name = name,
            .params = params_slice,
            .return_type = return_type,
            .body = body,
            .modifiers = modifiers,
        } };
        return node;
    }

    fn parseVarDecl(self: *Parser, var_type: VarType, modifiers: Modifiers) ParseError !*Node {
        // 获取变量名
        const name_tok = self.consume(.identifier, "Expected variable name") catch {
            return self.errorNode("Expected variable name after type");
        };
        if (name_tok.type == .token_error) {
            return self.errorNode("Expected variable name after type");
        }
        const name = try self.allocator.dupe(u8, name_tok.value.identifier);

        // 检查是否已存在
        if (self.sym_table.lookup(name) != null) {
            return self.errorNode("Variable already declared");
        }

        // 可选初始化
        var init_expr: ?*Node = null;
        if (self.match(.assign)) {
            init_expr = try self.parseExpression();
        }

        // 分号
        _ = self.consume(.semicolon, "Expected ';' after variable declaration") catch {
            return self.errorNode("Expected ';'");
        };

        if (var_type == .Class and self.last_class_name != null) {
            try self.sym_table.defineClassVar(name, self.last_class_name.?, modifiers);
        } else {
            try self.sym_table.define(name, var_type, modifiers);
        }
        // 创建AST节点
        const node = try self.allocator.create(Node);
        node.* = .{ .var_decl = .{
            .var_type = var_type,
            .name = name,
            .init = init_expr,
            .modifiers = modifiers,
        } };
        return node;
    }

    // ========== class 定义 ==========
    fn parseClassDef(self: *Parser, modifiers: Modifiers) ParseError !*Node {
        const name_tok = try self.consume(.identifier, "Expected class name after 'class'");
        const class_name = try self.allocator.dupe(u8, name_tok.value.identifier);

        // extends 父类
        var parent: ?[]const u8 = null;
        if (self.match(.kw_extends)) {
            const ptok = try self.consume(.identifier, "Expected parent class name after 'extends'");
            parent = try self.allocator.dupe(u8, ptok.value.identifier);
        }

        _ = try self.consume(.l_brace, "Expected '{' after class name");

        // 注册类到符号表
        try self.sym_table.defineClass(class_name, parent);

        // 如果有父类，复制父类字段到子类符号表
        if (parent) |pname| {
            if (self.sym_table.lookupClass(pname)) |pci| {
                var pit = pci.fields.iterator();
                while (pit.next()) |pentry| {
                    try self.sym_table.addField(class_name, pentry.key_ptr.*, pentry.value_ptr.*);
                }
            }
        }

        var fields: std.ArrayListUnmanaged(Field) = .empty;
        var methods: std.ArrayListUnmanaged(*Node) = .empty;

        while (!self.match(.r_brace)) {
            // 解析类成员修饰符
            const member_mods = self.parseModifiers();

            // 字段: int x;
            if (self.matchVarType()) |field_type| {
                const fname_tok = try self.consume(.identifier, "Expected field name");
                const fname = try self.allocator.dupe(u8, fname_tok.value.identifier);
                _ = try self.consume(.semicolon, "Expected ';' after field");
                try self.sym_table.addField(class_name, fname, field_type);
                try fields.append(self.allocator, Field{ .name = fname, .var_type = field_type, .modifiers = member_mods });
                continue;
            }

            // 方法: fn method() -> type { ... }
            if (self.match(.kw_fn)) {
                const mname_tok = try self.consume(.identifier, "Expected method name");
                const mname = try self.allocator.dupe(u8, mname_tok.value.identifier);

                // 参数列表
                _ = try self.consume(.l_paren, "Expected '(' after method name");
                var mparams: std.ArrayListUnmanaged(Param) = .empty;
                defer mparams.deinit(self.allocator);
                while (!self.match(.r_paren)) {
                    const pname_tok = try self.consume(.identifier, "Expected parameter name");
                    const pname = try self.allocator.dupe(u8, pname_tok.value.identifier);
                    _ = try self.consume(.colon, "Expected ':' after parameter name");
                    const ptype_tok = self.peek();
                    const ptype = self.typeFromToken(ptype_tok.type) orelse {
                        return self.errorNode("Expected parameter type");
                    };
                    _ = self.advance();
                    try mparams.append(self.allocator, Param{ .name = pname, .var_type = ptype });
                    if (!self.match(.comma)) {
                        _ = try self.consume(.r_paren, "Expected ')' or ',' after parameter");
                        break;
                    }
                }

                // 返回类型
                const return_type: VarType = if (self.match(.arrow)) blk: {
                    const rt_tok = self.peek();
                    const rt = self.typeFromToken(rt_tok.type) orelse return self.errorNode("Expected return type");
                    _ = self.advance();
                    break :blk rt;
                } else .Void;

                // 方法体 或 抽象方法分号
                const is_abstract_method = member_mods.abstract;
                var body: *Node = undefined;
                if (is_abstract_method) {
                    _ = try self.consume(.semicolon, "Expected ';' after abstract method");
                    body = try self.allocator.create(Node);
                    body.* = .{ .block = .{ .statements = &[_]*Node{} } };
                } else {
                    _ = try self.consume(.l_brace, "Expected '{' before method body");
                    body = try self.parseBlock();
                }

                const mparams_slice = try mparams.toOwnedSlice(self.allocator);
                try self.sym_table.addMethod(class_name, mname, FnSig{ .params = mparams_slice, .return_type = return_type });

                // 同时注册 ClassName_method 到全局函数表（含 self 参数）
                const full_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, mname });
                var self_params = try std.ArrayListUnmanaged(Param).initCapacity(self.allocator, mparams_slice.len + 1);
                // static 方法不注入 self
                if (!member_mods.static) {
                    try self_params.append(self.allocator, Param{ .name = "self", .var_type = .Class });
                }
                for (mparams_slice) |p| {
                    try self_params.append(self.allocator, p);
                }
                try self.sym_table.defineFn(full_name, try self_params.toOwnedSlice(self.allocator), return_type);

                const mnode = try self.allocator.create(Node);
                mnode.* = .{ .method_def = .{
                    .name = mname,
                    .class_name = class_name,
                    .params = mparams_slice,
                    .return_type = return_type,
                    .body = body,
                    .modifiers = member_mods,
                    .is_abstract = is_abstract_method,
                } };
                try methods.append(self.allocator, mnode);
                continue;
            }

            return self.errorNode("Expected field or method in class body");
        }

        const node = try self.allocator.create(Node);
        node.* = .{ .class_def = .{
            .name = class_name,
            .parent = parent,
            .fields = try fields.toOwnedSlice(self.allocator),
            .methods = try methods.toOwnedSlice(self.allocator),
            .modifiers = modifiers,
        } };
        return node;
    }

    // ========== new 表达式（数组创建）==========
    fn parseNewStmt(self: *Parser) ParseError !*Node {
        const node = try self.parseNewExpr();
        _ = self.consume(.semicolon, "Expected ';' after new expression") catch {
            return self.errorNode("Expected ';'");
        };
        const expr_node = try self.allocator.create(Node);
        expr_node.* = .{ .expr_stmt = .{ .expr = node } };
        return expr_node;
    }

    fn parseNewExpr(self: *Parser) ParseError !*Node {
        const type_tok = self.peek();
        const base_type = self.typeFromToken(type_tok.type) orelse {
            return self.errorNode("Expected type after 'new'");
        };
        _ = self.advance();
        _ = try self.consume(.l_bracket, "Expected '[' after type in new expression");
        const size = try self.parseExpression();
        _ = try self.consume(.r_bracket, "Expected ']' after size in new expression");
        const node = try self.allocator.create(Node);
        node.* = .{ .new_array = .{ .elem_type = base_type, .size = size } };
        return node;
    }

    fn parseNewObject(self: *Parser) ParseError !*Node {
        const name_tok = try self.consume(.identifier, "Expected class name after 'new'");
        const class_name = try self.allocator.dupe(u8, name_tok.value.identifier);
        _ = try self.consume(.l_paren, "Expected '(' after class name");
        var args: std.ArrayListUnmanaged(*Node) = .empty;
        defer args.deinit(self.allocator);
        if (!self.match(.r_paren)) {
            try args.append(self.allocator, try self.parseExpression());
            while (self.match(.comma)) {
                try args.append(self.allocator, try self.parseExpression());
            }
            _ = try self.consume(.r_paren, "Expected ')' after arguments");
        }
        const node = try self.allocator.create(Node);
        node.* = .{ .new_object = .{
            .class_name = class_name,
            .args = try args.toOwnedSlice(self.allocator),
        } };
        return node;
    }

    // ========== 代码块 ==========
    fn parseBlock(self: *Parser) ParseError !*Node {
        var statements: std.ArrayListUnmanaged(*Node) = .empty;
        defer statements.deinit(self.allocator);

        while (!self.isAtEnd() and !self.match(.r_brace)) {
            const stmt = try self.parseStatement();
            try statements.append(self.allocator, stmt);
        }

        const stmts = try statements.toOwnedSlice(self.allocator);
        const node = try self.allocator.create(Node);
        node.* = .{ .block = .{ .statements = stmts } };
        return node;
    }

    // ========== 表达式或赋值 ==========
    fn parseExprOrAssign(self: *Parser) ParseError !*Node {
        // 先解析左侧（可能是标识符或数组访问）
        const left = try self.parseExpression();

        // 如果是赋值语句
        if (self.match(.assign)) {
            // 数组赋值: a[0] = 42
            if (left.* == .array_access) {
                const arr_access = left.array_access;
                if (arr_access.array.* != .identifier) {
                    return self.errorNode("Invalid array assignment target");
                }
                const name = arr_access.array.identifier;
                if (self.sym_table.lookup(name) == null) {
                    return self.errorNode("Variable not declared");
                }
                const right = try self.parseExpression();
                _ = self.consume(.semicolon, "Expected ';' after assignment") catch {
                    return self.errorNode("Expected ';'");
                };
                const node = try self.allocator.create(Node);
                node.* = .{ .array_assign = .{
                    .name = try self.allocator.dupe(u8, name),
                    .index = arr_access.index,
                    .value = right,
                } };
                return node;
            }

            // 成员赋值: p.x = 42
            if (left.* == .member_access) {
                const ma = left.member_access;
                const right = try self.parseExpression();
                _ = self.consume(.semicolon, "Expected ';' after assignment") catch {
                    return self.errorNode("Expected ';'");
                };
                const node = try self.allocator.create(Node);
                node.* = .{ .member_assign = .{
                    .object = ma.object,
                    .member = try self.allocator.dupe(u8, ma.member),
                    .value = right,
                } };
                return node;
            }

            // 普通赋值: a = 42
            if (left.* != .identifier) {
                return self.errorNode("Invalid assignment target");
            }
            const name = left.identifier;

            // 检查变量是否存在
            if (self.sym_table.lookup(name) == null) {
                return self.errorNode("Variable not declared");
            }

            const right = try self.parseExpression();
            _ = self.consume(.semicolon, "Expected ';' after assignment") catch {
                return self.errorNode("Expected ';'");
            };

            const node = try self.allocator.create(Node);
            node.* = .{ .assign = .{
                .name = try self.allocator.dupe(u8, name),
                .value = right,
            } };
            return node;
        }

        // 否则是表达式语句
        _ = self.consume(.semicolon, "Expected ';' after expression") catch {
            return self.errorNode("Expected ';'");
        };

        const node = try self.allocator.create(Node);
        node.* = .{ .expr_stmt = .{ .expr = left } };
        return node;
    }

    // 解析表达式（入口）
    pub fn parseExpression(self: *Parser) ParseError !*Node {
        return self.parseAssignment();
    }

    // 赋值（最低优先级，当前仅支持基础表达式，赋值后续再加）
    fn parseAssignment(self: *Parser) ParseError !*Node {
        const node = try self.parseLogicalOr();
        // 支持简单赋值表达式: x = expr
        if (self.match(.assign)) {
            if (node.* == .identifier) {
                const name = try self.allocator.dupe(u8, node.identifier);
                const value = try self.parseAssignment();
                const new_node = try self.allocator.create(Node);
                new_node.* = .{ .assign = .{ .name = name, .value = value } };
                return new_node;
            }
        }
        return node;
    }

    // 逻辑或 (||)
    fn parseLogicalOr(self: *Parser) ParseError !*Node {
        var node = try self.parseLogicalAnd();
        while (self.match(.bool_or)) {
            const op_token = self.previous();
            const right = try self.parseLogicalAnd();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .binary = .{
                    .op = self.opFromToken(op_token),
                    .left = node,
                    .right = right,
                },
            };
            node = new_node;
        }
        return node;
    }

    // 逻辑与 (&&)
    fn parseLogicalAnd(self: *Parser) ParseError !*Node {
        var node = try self.parseEquality();
        while (self.match(.bool_and)) {
            const op_token = self.previous();
            const right = try self.parseEquality();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .binary = .{
                    .op = self.opFromToken(op_token),
                    .left = node,
                    .right = right,
                },
            };
            node = new_node;
        }
        return node;
    }

    // 相等性 (==, !=)
    fn parseEquality(self: *Parser) ParseError !*Node {
        var node = try self.parseComparison();
        while (self.match(.equal) or self.match(.not_equal)) {
            const op_token = self.previous();
            const right = try self.parseComparison();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .binary = .{
                    .op = self.opFromToken(op_token),
                    .left = node,
                    .right = right,
                },
            };
            node = new_node;
        }
        return node;
    }

    // 比较 (>, <, >=, <=)
    fn parseComparison(self: *Parser) ParseError !*Node {
        var node = try self.parseTerm();
        while (self.match(.greater) or self.match(.greater_equal) or
            self.match(.less) or self.match(.less_equal))
        {
            const op_token = self.previous();
            const right = try self.parseTerm();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .binary = .{
                    .op = self.opFromToken(op_token),
                    .left = node,
                    .right = right,
                },
            };
            node = new_node;
        }
        return node;
    }

    // 加减法 (+, -)
    fn parseTerm(self: *Parser) ParseError !*Node {
        var node = try self.parseFactor();
        while (self.match(.plus) or self.match(.minus)) {
            const op_token = self.previous();
            const right = try self.parseFactor();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .binary = .{
                    .op = self.opFromToken(op_token),
                    .left = node,
                    .right = right,
                },
            };
            node = new_node;
        }
        return node;
    }

    // 乘除法 (*, /, %)
    fn parseFactor(self: *Parser) ParseError !*Node {
        var node = try self.parseUnary();
        while (self.match(.star) or self.match(.slash) or self.match(.percent)) {
            const op_token = self.previous();
            const right = try self.parseUnary();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .binary = .{
                    .op = self.opFromToken(op_token),
                    .left = node,
                    .right = right,
                },
            };
            node = new_node;
        }
        return node;
    }

    // 一元运算 (暂只支持负数)
    fn parseUnary(self: *Parser) ParseError !*Node {
        if (self.match(.minus)) {
            const expr = try self.parseUnary();
            const new_node = try self.allocator.create(Node);
            new_node.* = .{
                .unary = .{
                    .op = .sub,
                    .expr = expr,
                },
            };
            return new_node;
        }
        return self.parsePrimary();
    }

    // 基础表达式：数字、字符串、标识符、括号、函数调用
    fn parsePrimary(self: *Parser) ParseError !*Node {
        if (self.match(.literal_int)) {
            const tok = self.previous();
            const node = try self.allocator.create(Node);
            node.* = .{ .int_literal = tok.value.int };
            return node;
        }
        if (self.match(.literal_long)) {
            const tok = self.previous();
            const node = try self.allocator.create(Node);
            node.* = .{ .long_literal = tok.value.long };
            return node;
        }
        if (self.match(.literal_float)) {
            const tok = self.previous();
            const node = try self.allocator.create(Node);
            node.* = .{ .float_literal = @floatCast(tok.value.float) };
            return node;
        }
        if (self.match(.literal_double)) {
            const tok = self.previous();
            const node = try self.allocator.create(Node);
            node.* = .{ .double_literal = tok.value.double };
            return node;
        }
        if (self.match(.literal_char)) {
            const tok = self.previous();
            const node = try self.allocator.create(Node);
            node.* = .{ .char_literal = @intCast(tok.value.char) };
            return node;
        }
        if (self.match(.literal_string)) {
            const tok = self.previous();
            const str = try self.allocator.dupe(u8, tok.value.string);
            const node = try self.allocator.create(Node);
            node.* = .{ .string_literal = str };
            return node;
        }
        if (self.match(.literal_boolean)) {
            const tok = self.previous();
            const node = try self.allocator.create(Node);
            node.* = .{ .boolean_literal = tok.value.boolean };
            return node;
        }
        if (self.match(.identifier)) {
            const tok = self.previous();
            const name = try self.allocator.dupe(u8, tok.value.identifier);

            // 如果后面跟 '('，则是函数调用
            if (self.match(.l_paren)) {
                var args: std.ArrayListUnmanaged(*Node) = .empty;
                defer args.deinit(self.allocator);
                if (!self.match(.r_paren)) {
                    try args.append(self.allocator, try self.parseExpression());
                    while (self.match(.comma)) {
                        try args.append(self.allocator, try self.parseExpression());
                    }
                    _ = try self.consume(.r_paren, "Expected ')' after arguments");
                }
                const node = try self.allocator.create(Node);
                node.* = .{ .call = .{
                    .callee = name,
                    .args = try args.toOwnedSlice(self.allocator),
                } };
                return node;
            }

            // 如果后面跟 '['，则是数组访问: a[0]
            if (self.match(.l_bracket)) {
                const index = try self.parseExpression();
                _ = try self.consume(.r_bracket, "Expected ']' after index");
                const id_node = try self.allocator.create(Node);
                id_node.* = .{ .identifier = name };
                const node = try self.allocator.create(Node);
                node.* = .{ .array_access = .{ .array = id_node, .index = index } };
                return node;
            }

            // 如果后面跟 '.'，则是成员访问: p.x 或方法调用: p.sum()
            if (self.match(.dot)) {
                const member_tok = try self.consume(.identifier, "Expected member name after '.'");
                const member = try self.allocator.dupe(u8, member_tok.value.identifier);

                // 如果后面跟 '('，则是方法调用: p.sum(args)
                if (self.match(.l_paren)) {
                    const obj_node = try self.allocator.create(Node);
                    obj_node.* = .{ .identifier = name };

                    // 查找对象的类名（或类名直接调用静态方法）
                    const class_name = if (self.sym_table.isClass(name))
                        name
                    else if (self.sym_table.lookup(name)) |s|
                        s.class_name orelse "Object"
                    else
                        "Object";
                    const method_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ class_name, member });

                    var args: std.ArrayListUnmanaged(*Node) = .empty;
                    defer args.deinit(self.allocator);

                    // 检查方法是否为 static:
                    // 1) 类名直接调用（Point.origin()）一定是 static
                    // 2) 查符号表中 ClassName_method 签名，第一个参数不是 self
                    const is_static_call = self.sym_table.isClass(name);
                    const method_sig = self.sym_table.lookupFn(method_name);
                    const is_static = is_static_call or (if (method_sig) |sig|
                        sig.params.len == 0 or !std.mem.eql(u8, sig.params[0].name, "self")
                    else
                        false);

                    // 非 static 方法需要 self 作为第一个参数
                    if (!is_static) {
                        try args.append(self.allocator, obj_node);
                    }
                    if (!self.match(.r_paren)) {
                        try args.append(self.allocator, try self.parseExpression());
                        while (self.match(.comma)) {
                            try args.append(self.allocator, try self.parseExpression());
                        }
                        _ = try self.consume(.r_paren, "Expected ')' after arguments");
                    }
                    const node = try self.allocator.create(Node);
                    node.* = .{ .call = .{
                        .callee = method_name,
                        .args = try args.toOwnedSlice(self.allocator),
                    } };
                    return node;
                }

                // 否则是普通成员访问
                const obj_node = try self.allocator.create(Node);
                obj_node.* = .{ .identifier = name };
                const node = try self.allocator.create(Node);
                node.* = .{ .member_access = .{ .object = obj_node, .member = member } };
                return node;
            }

            const node = try self.allocator.create(Node);
            node.* = .{ .identifier = name };
            return node;
        }
        if (self.match(.l_paren)) {
            const expr = try self.parseExpression();
            _ = try self.consume(.r_paren, "Expected ')' after expression");
            return expr;
        }
        // this 关键字
        if (self.match(.kw_this)) {
            const this_node = try self.allocator.create(Node);
            this_node.* = .{ .this_expr = {} };

            // 如果后面跟 '.'，则是成员访问: this.x
            if (self.match(.dot)) {
                const member_tok = try self.consume(.identifier, "Expected member name after '.'");
                const member = try self.allocator.dupe(u8, member_tok.value.identifier);
                const node = try self.allocator.create(Node);
                node.* = .{ .member_access = .{ .object = this_node, .member = member } };
                return node;
            }

            return this_node;
        }
        // new 表达式: new int[5] 或 new ClassName(args)
        if (self.match(.kw_new)) {
            // 看后面是类型关键字还是标识符(类名)
            if (!self.isAtEnd() and self.peek().type == .identifier and
                self.sym_table.isClass(self.peek().value.identifier))
            {
                return self.parseNewObject();
            }
            return self.parseNewExpr();
        }
        return self.errorNode("Expected expression");
    }

    // ========== 辅助函数 ==========
    /// 解析修饰符序列（public/private/protected/static/final/abstract）
    fn parseModifiers(self: *Parser) Modifiers {
        var mods = Modifiers{};
        while (true) {
            switch (self.peek().type) {
                .kw_public => { mods.public = true; _ = self.advance(); },
                .kw_private => { mods.private = true; _ = self.advance(); },
                .kw_protected => { mods.protected = true; _ = self.advance(); },
                .kw_static => { mods.static = true; _ = self.advance(); },
                .kw_final => { mods.final = true; _ = self.advance(); },
                .kw_abstract => { mods.abstract = true; _ = self.advance(); },
                else => break,
            }
        }
        return mods;
    }

    fn match(self: *Parser, expected: TokenType) bool {
        if (self.isAtEnd()) return false;
        if (self.peek().type == expected) {
            _ = self.advance();
            return true;
        }
        return false;
    }

    fn consume(self: *Parser, expected: TokenType, err_msg: []const u8) !Token {
        if (self.peek().type == expected) {
            return self.advance();
        }
        return self.errorToken(err_msg);
    }

    pub fn peek(self: *Parser) Token {
        return self.tokens[self.index];
    }

    fn peekNext(self: *Parser) Token {
        if (self.index + 1 >= self.tokens.len) return self.tokens[self.tokens.len - 1];
        return self.tokens[self.index + 1];
    }

    fn advance(self: *Parser) Token {
        const tok = self.tokens[self.index];
        self.index += 1;
        return tok;
    }

    pub fn previous(self: *Parser) Token {
        return self.tokens[self.index - 1];
    }

    pub fn isAtEnd(self: *Parser) bool {
        return self.index >= self.tokens.len or self.peek().type == .eof;
    }


    fn opFromToken(self: *Parser, tok: Token) Op {
        _ = self;
        return switch (tok.type) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .equal => .eq,
            .not_equal => .neq,
            .less => .lt,
            .greater => .gt,
            .less_equal => .le,
            .greater_equal => .ge,
            .bool_and => .bool_and,
            .bool_or => .bool_or,
            else => .add,
        };
    }

    fn errorNode(self: *Parser, msg: []const u8) ParseError !*Node {
        const node = try self.allocator.create(Node);
        node.* = .{ .token_error = msg };
        return node;
    }

    fn errorToken(self: *Parser, msg: []const u8) !Token {
        const tok = self.peek();
        return Token{
            .type = .token_error,
            .value = .none,
            .line = tok.line,
            .column = tok.column,
            .lexeme = msg,
        };
    }

    // ========== if 语句解析 ==========
    fn parseIf(self: *Parser) ParseError !*Node {
        _ = try self.consume(.l_paren, "Expected '(' after if");
        const condition = try self.parseExpression();
        _ = try self.consume(.r_paren, "Expected ')' after condition");

        const then_branch = try self.parseStatement();

        var else_branch: ?*Node = null;
        if (self.match(.kw_else)) {
            else_branch = try self.parseStatement();
        }

        const node = try self.allocator.create(Node);
        node.* = .{ .if_stmt = .{
            .condition = condition,
            .then_branch = then_branch,
            .else_branch = else_branch,
        } };
        return node;
    }

    // ========== while 语句解析 ==========
    fn parseWhile(self: *Parser) ParseError !*Node {
        _ = try self.consume(.l_paren, "Expected '(' after while");
        const condition = try self.parseExpression();
        _ = try self.consume(.r_paren, "Expected ')' after condition");

        const body = try self.parseStatement();

        const node = try self.allocator.create(Node);
        node.* = .{ .while_stmt = .{
            .condition = condition,
            .body = body,
        } };
        return node;
    }

    // ========== for 语句解析 ==========
    fn parseFor(self: *Parser) ParseError !*Node {
        _ = try self.consume(.l_paren, "Expected '(' after for");

        // Init: var_decl 或 表达式 或 空
        var init_node: ?*Node = null;
        if (self.matchVarType()) |var_type| {
            // 变量声明（不在末尾消费 ;）
            const name_tok = self.consume(.identifier, "Expected variable name") catch
                return self.errorNode("Expected variable name after type");
            const name = try self.allocator.dupe(u8, name_tok.value.identifier);
            var init_expr: ?*Node = null;
            if (self.match(.assign)) {
                init_expr = try self.parseExpression();
            }
            const node = try self.allocator.create(Node);
            node.* = .{ .var_decl = .{
                .var_type = var_type,
                .name = name,
                .init = init_expr,
            } };
            init_node = node;
            _ = try self.consume(.semicolon, "Expected ';' after for init");
        } else if (!self.match(.semicolon)) {
            init_node = try self.parseExpression();
            _ = try self.consume(.semicolon, "Expected ';' after for init");
        }

        // Condition: 表达式 或 空
        var condition: ?*Node = null;
        if (!self.match(.semicolon)) {
            condition = try self.parseExpression();
            _ = try self.consume(.semicolon, "Expected ';' after for condition");
        }

        // Update: 表达式 或 空
        var update: ?*Node = null;
        if (!self.match(.r_paren)) {
            update = try self.parseExpression();
            _ = try self.consume(.r_paren, "Expected ')' after for update");
        }

        const body = try self.parseStatement();

        const node = try self.allocator.create(Node);
        node.* = .{ .for_stmt = .{
            .init = init_node,
            .condition = condition,
            .update = update,
            .body = body,
        } };
        return node;
    }

    // ========== do-while 语句解析 ==========
    fn parseDoWhile(self: *Parser) ParseError !*Node {
        const body = try self.parseStatement();
        _ = try self.consume(.kw_while, "Expected 'while' after do body");
        _ = try self.consume(.l_paren, "Expected '(' after while");
        const condition = try self.parseExpression();
        _ = try self.consume(.r_paren, "Expected ')' after condition");
        _ = try self.consume(.semicolon, "Expected ';' after do-while");

        const node = try self.allocator.create(Node);
        node.* = .{ .do_while_stmt = .{
            .body = body,
            .condition = condition,
        } };
        return node;
    }

    // ========== switch 语句解析 ==========
    fn parseSwitch(self: *Parser) ParseError !*Node {
        _ = try self.consume(.l_paren, "Expected '(' after switch");
        const expr = try self.parseExpression();
        _ = try self.consume(.r_paren, "Expected ')' after switch expression");
        _ = try self.consume(.l_brace, "Expected '{' after switch");

        var cases: std.ArrayListUnmanaged(SwitchCase) = .empty;
        defer cases.deinit(self.allocator);
        var default_body: ?*Node = null;

        while (!self.match(.r_brace)) {
            if (self.match(.kw_case)) {
                // case 1, 2, 3:
                var values: std.ArrayListUnmanaged(i64) = .empty;
                defer values.deinit(self.allocator);
                while (true) {
                    const val: i64 = switch (self.peek().type) {
                        .literal_int => blk: { const v = self.peek().value.int; _ = self.advance(); break :blk v; },
                        .literal_char => blk: { const v: i64 = self.peek().value.char; _ = self.advance(); break :blk v; },
                        else => return self.errorNode("Expected int or char literal in case"),
                    };
                    try values.append(self.allocator, val);
                    if (!self.match(.comma)) break;
                }
                _ = try self.consume(.colon, "Expected ':' after case value");

                // 解析 case body（直到 break 或下一个 case/default 或 }）
                var stmts: std.ArrayListUnmanaged(*Node) = .empty;
                defer stmts.deinit(self.allocator);
                while (!self.isAtEnd() and
                       self.peek().type != .r_brace and
                       self.peek().type != .kw_case and
                       self.peek().type != .kw_default) {
                    if (self.match(.kw_break)) {
                        _ = try self.consume(.semicolon, "Expected ';' after break");
                        break;
                    }
                    const stmt = try self.parseStatement();
                    try stmts.append(self.allocator, stmt);
                }
                const body = try self.allocator.create(Node);
                body.* = .{ .block = .{ .statements = try stmts.toOwnedSlice(self.allocator) } };
                try cases.append(self.allocator, SwitchCase{
                    .values = try values.toOwnedSlice(self.allocator),
                    .body = body,
                });
            } else if (self.match(.kw_default)) {
                _ = try self.consume(.colon, "Expected ':' after default");
                var stmts: std.ArrayListUnmanaged(*Node) = .empty;
                defer stmts.deinit(self.allocator);
                while (!self.isAtEnd() and self.peek().type != .r_brace) {
                    if (self.match(.kw_break)) {
                        _ = try self.consume(.semicolon, "Expected ';' after break");
                        break;
                    }
                    const stmt = try self.parseStatement();
                    try stmts.append(self.allocator, stmt);
                }
                const body = try self.allocator.create(Node);
                body.* = .{ .block = .{ .statements = try stmts.toOwnedSlice(self.allocator) } };
                default_body = body;
            } else {
                return self.errorNode("Expected 'case' or 'default' in switch");
            }
        }

        const node = try self.allocator.create(Node);
        node.* = .{ .switch_stmt = .{
            .expr = expr,
            .cases = try cases.toOwnedSlice(self.allocator),
            .default_body = default_body,
        } };
        return node;
    }

    // ========== enum 定义解析 ==========
    fn parseEnum(self: *Parser) ParseError !*Node {
        const name_tok = try self.consume(.identifier, "Expected enum name");
        const name = try self.allocator.dupe(u8, name_tok.value.identifier);
        _ = try self.consume(.l_brace, "Expected '{' after enum name");

        var values: std.ArrayListUnmanaged([]const u8) = .empty;
        defer values.deinit(self.allocator);

        while (!self.match(.r_brace)) {
            const val_tok = try self.consume(.identifier, "Expected enum value name");
            try values.append(self.allocator, try self.allocator.dupe(u8, val_tok.value.identifier));
            _ = self.match(.comma); // 逗号可选
        }

        const node = try self.allocator.create(Node);
        node.* = .{ .enum_def = .{
            .name = name,
            .values = try values.toOwnedSlice(self.allocator),
        } };
        return node;
    }

    // ========== interface 定义解析 ==========
    fn parseInterface(self: *Parser) ParseError !*Node {
        const name_tok = try self.consume(.identifier, "Expected interface name");
        const name = try self.allocator.dupe(u8, name_tok.value.identifier);
        _ = try self.consume(.l_brace, "Expected '{' after interface name");
        var methods: std.ArrayListUnmanaged(*Node) = .empty;
        defer methods.deinit(self.allocator);
        while (!self.match(.r_brace)) {
            _ = try self.consume(.kw_fn, "Expected 'fn' in interface");
            const mname_tok = try self.consume(.identifier, "Expected method name");
            const mname = try self.allocator.dupe(u8, mname_tok.value.identifier);
            _ = try self.consume(.l_paren, "Expected '('");
            _ = try self.consume(.r_paren, "Expected ')'");
            const return_type: VarType = if (self.match(.arrow)) blk: {
                const rt = self.typeFromToken(self.peek().type) orelse return self.errorNode("Expected return type");
                _ = self.advance();
                break :blk rt;
            } else .Void;
            _ = try self.consume(.semicolon, "Expected ';' after interface method");
            const empty_body = try self.allocator.create(Node);
            empty_body.* = .{ .block = .{ .statements = &[_]*Node{} } };
            const mnode = try self.allocator.create(Node);
            mnode.* = .{ .method_def = .{
                .name = mname, .class_name = name, .params = &[_]Param{},
                .return_type = return_type, .body = empty_body, .is_abstract = true,
            } };
            try methods.append(self.allocator, mnode);
        }
        const node = try self.allocator.create(Node);
        node.* = .{ .interface_def = .{ .name = name, .methods = try methods.toOwnedSlice(self.allocator) } };
        return node;
    }

    // ========== package 声明解析 ==========
    fn parsePackage(self: *Parser) ParseError !*Node {
        var parts: std.ArrayListUnmanaged(u8) = .empty;
        defer parts.deinit(self.allocator);
        while (true) {
            const part = try self.consume(.identifier, "Expected package name");
            try parts.appendSlice(self.allocator, part.value.identifier);
            if (!self.match(.dot)) break;
            try parts.append(self.allocator, '.');
        }
        _ = try self.consume(.semicolon, "Expected ';' after package");
        const node = try self.allocator.create(Node);
        node.* = .{ .package_stmt = try parts.toOwnedSlice(self.allocator) };
        return node;
    }

    // ========== return 语句解析 ==========
    fn parseReturn(self: *Parser) ParseError !*Node {
        var value: ?*Node = null;
        if (!self.match(.semicolon)) {
            value = try self.parseExpression();
            _ = try self.consume(.semicolon, "Expected ';' after return value");
        }
        const node = try self.allocator.create(Node);
        node.* = .{ .return_stmt = .{ .value = value } };
        return node;
    }

    // ========== TokenType → VarType 映射 ==========
    fn typeFromToken(self: *Parser, tt: TokenType) ?VarType {
        return switch (tt) {
            .kw_int => .Int,
            .kw_long => .Long,
            .kw_float => .Float,
            .kw_double => .Double,
            .kw_char => .Char,
            .kw_string, .kw_String => .String,
            .kw_boolean => .Boolean,
            .kw_void => .Void,
            .identifier => {
                // 检查是否是已知类名
                if (self.sym_table.isClass(self.peek().value.identifier)) {
                    return .Class;
                }
                return null;
            },
            else => null,
        };
    }
};

// ========== AST 打印函数 ==========
pub fn printNode(node: *const Node, indent: usize, writer: anytype) !void {
    const spaces = "                                          "[0..indent];
    switch (node.*) {
        .int_literal => |v| try writer.print("{s}Int({d})\n", .{ spaces, v }),
        .long_literal => |v| try writer.print("{s}Long({d})\n", .{ spaces, v }),
        .float_literal => |v| try writer.print("{s}Float({d})\n", .{ spaces, v }),
        .double_literal => |v| try writer.print("{s}Double({d})\n", .{ spaces, v }),
        .char_literal => |c| try writer.print("{s}Char('{c}')\n", .{ spaces, c }),
        .string_literal => |s| try writer.print("{s}String(\"{s}\")\n", .{ spaces, s }),
        .boolean_literal => |b| try writer.print("{s}Boolean({})\n", .{ spaces, b }),
        .identifier => |id| try writer.print("{s}Id({s})\n", .{ spaces, id }),
        .binary => |b| {
            try writer.print("{s}Binary({any})\n", .{ spaces, b.op });
            try printNode(b.left, indent + 2, writer);
            try printNode(b.right, indent + 2, writer);
        },
        .unary => |u| {
            try writer.print("{s}Unary({any})\n", .{ spaces, u.op });
            try printNode(u.expr, indent + 2, writer);
        },
        .call => |c| {
            try writer.print("{s}Call({s})\n", .{ spaces, c.callee });
            for (c.args) |arg| {
                try printNode(arg, indent + 2, writer);
            }
        },
        .var_decl => |vd| {
            try writer.print("{s}VarDecl({any}, {s})\n", .{ spaces, vd.var_type, vd.name });
            if (vd.init) |init_expr| {
                try printNode(init_expr, indent + 2, writer);
            }
        },
        .assign => |a| {
            try writer.print("{s}Assign({s})\n", .{ spaces, a.name });
            try printNode(a.value, indent + 2, writer);
        },
        .block => |b| {
            try writer.print("{s}Block\n", .{ spaces });
            for (b.statements) |stmt| {
                try printNode(stmt, indent + 2, writer);
            }
        },
        .expr_stmt => |e| {
            try writer.print("{s}ExprStmt\n", .{ spaces });
            try printNode(e.expr, indent + 2, writer);
        },
        .token_error => |msg| try writer.print("{s}Error({s})\n", .{ spaces, msg }),

        .if_stmt => |i| {
            try writer.print("{s}If\n", .{spaces});
            try writer.print("{s}  Condition:\n", .{spaces});
            try printNode(i.condition, indent + 4, writer);
            try writer.print("{s}  Then:\n", .{spaces});
            try printNode(i.then_branch, indent + 4, writer);
            if (i.else_branch) |else_branch| {
                try writer.print("{s}  Else:\n", .{spaces});
                try printNode(else_branch, indent + 4, writer);
            }
        },
        .while_stmt => |w| {
            try writer.print("{s}While\n", .{spaces});
            try writer.print("{s}  Condition:\n", .{spaces});
            try printNode(w.condition, indent + 4, writer);
            try writer.print("{s}  Body:\n", .{spaces});
            try printNode(w.body, indent + 4, writer);
        },
        .for_stmt => |f| {
            try writer.print("{s}For\n", .{spaces});
            if (f.init) |n| { try writer.print("{s}  Init:\n", .{spaces}); try printNode(n, indent + 4, writer); }
            try writer.print("{s}  Cond:\n", .{spaces});
            if (f.condition) |c| try printNode(c, indent + 4, writer) else try writer.print("{s}    (always)\n", .{spaces});
            if (f.update) |u| { try writer.print("{s}  Update:\n", .{spaces}); try printNode(u, indent + 4, writer); }
            try writer.print("{s}  Body:\n", .{spaces});
            try printNode(f.body, indent + 4, writer);
        },
        .do_while_stmt => |dw| {
            try writer.print("{s}DoWhile\n", .{spaces});
            try writer.print("{s}  Body:\n", .{spaces});
            try printNode(dw.body, indent + 4, writer);
            try writer.print("{s}  Cond:\n", .{spaces});
            try printNode(dw.condition, indent + 4, writer);
        },

        .switch_stmt => |sw| {
            try writer.print("{s}Switch\n", .{spaces});
            try printNode(sw.expr, indent + 2, writer);
            for (sw.cases) |c| {
                try writer.print("{s} Case:", .{spaces});
                for (c.values) |v| try writer.print(" {d}", .{v});
                try writer.print("\n", .{});
                try printNode(c.body, indent + 4, writer);
            }
            if (sw.default_body) |def| {
                try writer.print("{s} Default:\n", .{spaces});
                try printNode(def, indent + 4, writer);
            }
        },

        .fn_def => |f| {
            try writer.print("{s}FnDef({s}) -> {any}\n", .{ spaces, f.name, f.return_type });
            for (f.params) |param| {
                try writer.print("{s}  Param({s}: {any})\n", .{ spaces, param.name, param.var_type });
            }
            try writer.print("{s}  Body:\n", .{spaces});
            try printNode(f.body, indent + 4, writer);
        },
        .return_stmt => |r| {
            try writer.print("{s}Return", .{spaces});
            if (r.value) |val| {
                try writer.print("\n", .{});
                try printNode(val, indent + 4, writer);
            } else {
                try writer.print("\n", .{});
            }
        },

        .new_array => |na| {
            try writer.print("{s}NewArray({any})\n", .{ spaces, na.elem_type });
            try printNode(na.size, indent + 2, writer);
        },
        .array_access => |aa| {
            try writer.print("{s}ArrayAccess\n", .{spaces});
            try printNode(aa.array, indent + 2, writer);
            try writer.print("{s}  Index:\n", .{spaces});
            try printNode(aa.index, indent + 4, writer);
        },
        .array_assign => |aa| {
            try writer.print("{s}ArrayAssign({s})\n", .{ spaces, aa.name });
            try writer.print("{s}  Index:\n", .{spaces});
            try printNode(aa.index, indent + 4, writer);
            try writer.print("{s}  Value:\n", .{spaces});
            try printNode(aa.value, indent + 4, writer);
        },
        .import_stmt => |path| try writer.print("{s}Import(\"{s}\")\n", .{ spaces, path }),

        .enum_def => |ed| {
            try writer.print("{s}Enum({s})\n", .{ spaces, ed.name });
        },

        .interface_def => |iface| {
            try writer.print("{s}Interface({s})\n", .{ spaces, iface.name });
        },

        .package_stmt => |pkg| try writer.print("{s}Package({s})\n", .{ spaces, pkg }),

        .class_def => |cd| {
            try writer.print("{s}Class({s})\n", .{ spaces, cd.name });
            for (cd.fields) |f| {
                try writer.print("{s}  Field({s}: {any})\n", .{ spaces, f.name, f.var_type });
            }
            for (cd.methods) |m| {
                try printNode(m, indent + 2, writer);
            }
        },
        .method_def => |md| {
            try writer.print("{s}Method({s}) -> {any}\n", .{ spaces, md.name, md.return_type });
            try printNode(md.body, indent + 2, writer);
        },
        .field => |f| try writer.print("{s}FieldRef({s})\n", .{ spaces, f.name }),
        .new_object => |no| {
            try writer.print("{s}New({s})\n", .{ spaces, no.class_name });
            for (no.args) |arg| try printNode(arg, indent + 2, writer);
        },
        .member_access => |ma| {
            try writer.print("{s}MemberAccess({s})\n", .{ spaces, ma.member });
            try printNode(ma.object, indent + 2, writer);
        },
        .member_assign => |ma| {
            try writer.print("{s}MemberAssign({s})\n", .{ spaces, ma.member });
            try printNode(ma.value, indent + 2, writer);
        },
        .this_expr => try writer.print("{s}This\n", .{spaces}),

    }
}

// ==================================================================
// 单元测试
// ==================================================================

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expectEqualStrings = testing.expectEqualStrings;
const expect = testing.expect;

/// 辅助函数：将 Javix 源码词法分析并收集为 Token 列表
fn tokenizeSource(allocator: std.mem.Allocator, source: []const u8) !std.ArrayList(Token) {
    const Lexer = @import("lexer.zig").Lexer;
    var lex = Lexer.init(allocator, source);
    var tokens = std.ArrayList(Token).init(allocator);
    while (true) {
        const tok = try lex.nextToken();
        const is_eof = tok.type == .eof;
        try tokens.append(tok);
        if (is_eof) break;
    }
    return tokens;
}

/// 释放 token 列表中的堆内存
fn freeTokens(tokens: *std.ArrayList(Token), allocator: std.mem.Allocator) void {
    for (tokens.items) |*tok| {
        switch (tok.value) {
            .string => |s| allocator.free(s),
            .identifier => |s| allocator.free(s),
            else => {},
        }
    }
    tokens.deinit();
}

// ---- 表达式解析 ----

test "parser: integer literal" {
    var tokens = try tokenizeSource(testing.allocator, "42");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseExpression();
    try expect(node.* == .int_literal);
    try expectEqual(@as(i64, 42), node.int_literal);
}

test "parser: simple addition" {
    var tokens = try tokenizeSource(testing.allocator, "1 + 2");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseExpression();
    try expect(node.* == .binary);
    try expectEqual(Op.add, node.binary.op);
    try expect(node.binary.left.* == .int_literal);
    try expectEqual(@as(i64, 1), node.binary.left.int_literal);
    try expect(node.binary.right.* == .int_literal);
    try expectEqual(@as(i64, 2), node.binary.right.int_literal);
}

test "parser: multiplication precedence" {
    // 1 + 2 * 3 应该解析为 1 + (2 * 3)
    var tokens = try tokenizeSource(testing.allocator, "1 + 2 * 3");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseExpression();
    try expect(node.* == .binary);
    try expectEqual(Op.add, node.binary.op); // 顶层是 +
    try expect(node.binary.left.* == .int_literal);
    try expectEqual(@as(i64, 1), node.binary.left.int_literal);
    // 右子树应该是 2 * 3
    try expect(node.binary.right.* == .binary);
    try expectEqual(Op.mul, node.binary.right.binary.op);
}

test "parser: comparison expression" {
    var tokens = try tokenizeSource(testing.allocator, "a > b");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseExpression();
    try expect(node.* == .binary);
    try expectEqual(Op.gt, node.binary.op);
    try expect(node.binary.left.* == .identifier);
    try expectEqualStrings("a", node.binary.left.identifier);
    try expect(node.binary.right.* == .identifier);
    try expectEqualStrings("b", node.binary.right.identifier);
}

test "parser: logical and" {
    var tokens = try tokenizeSource(testing.allocator, "x && y");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseExpression();
    try expect(node.* == .binary);
    try expectEqual(Op.bool_and, node.binary.op);
}

// ---- 语句解析 ----

test "parser: variable declaration" {
    var tokens = try tokenizeSource(testing.allocator, "int x = 42;");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .var_decl);
    try expectEqual(VarType.Int, node.var_decl.var_type);
    try expectEqualStrings("x", node.var_decl.name);
    try expect(node.var_decl.init != null);
    try expect(node.var_decl.init.?.* == .int_literal);
}

test "parser: variable declaration without init" {
    var tokens = try tokenizeSource(testing.allocator, "double value;");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .var_decl);
    try expectEqual(VarType.Double, node.var_decl.var_type);
    try expectEqualStrings("value", node.var_decl.name);
    try expect(node.var_decl.init == null);
}

test "parser: assignment" {
    var tokens = try tokenizeSource(testing.allocator, "x = 100;");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .assign);
    try expectEqualStrings("x", node.assign.name);
    try expect(node.assign.value.* == .int_literal);
    try expectEqual(@as(i64, 100), node.assign.value.int_literal);
}

test "parser: if statement" {
    var tokens = try tokenizeSource(testing.allocator, "if (x > 0) x = 1;");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .if_stmt);
    // condition 应该是 x > 0
    try expect(node.if_stmt.condition.* == .binary);
    try expectEqual(Op.gt, node.if_stmt.condition.binary.op);
    // then_branch 应该是 x = 1
    try expect(node.if_stmt.then_branch.* == .assign);
    // else_branch 应该是 null
    try expect(node.if_stmt.else_branch == null);
}

test "parser: if-else statement" {
    var tokens = try tokenizeSource(testing.allocator, "if (x) a = 1; else a = 2;");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .if_stmt);
    try expect(node.if_stmt.else_branch != null);
    try expect(node.if_stmt.else_branch.?.* == .assign);
}

test "parser: while loop" {
    var tokens = try tokenizeSource(testing.allocator, "while (x < 10) x = x + 1;");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .while_stmt);
    try expect(node.while_stmt.condition.* == .binary);
    try expect(node.while_stmt.body.* == .assign);
}

test "parser: return statement" {
    var tokens = try tokenizeSource(testing.allocator, "return 42;");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .return_stmt);
    try expect(node.return_stmt.value != null);
    try expect(node.return_stmt.value.?.* == .int_literal);
}

test "parser: block statement" {
    var tokens = try tokenizeSource(testing.allocator, "{ x = 1; y = 2; }");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .block);
    try expectEqual(@as(usize, 2), node.block.statements.len);
    try expect(node.block.statements[0].* == .assign);
    try expect(node.block.statements[1].* == .assign);
}

test "parser: function definition" {
    var tokens = try tokenizeSource(testing.allocator, "fn add(a: int, b: int) { return a + b; }");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .fn_def);
    try expectEqualStrings("add", node.fn_def.name);
    try expectEqual(@as(usize, 2), node.fn_def.params.len);
    try expectEqualStrings("a", node.fn_def.params[0].name);
    try expectEqual(VarType.Int, node.fn_def.params[0].var_type);
    try expectEqualStrings("b", node.fn_def.params[1].name);
    try expectEqual(VarType.Int, node.fn_def.params[1].var_type);
    try expect(node.fn_def.body.* == .block);
}

test "parser: simple class definition" {
    var tokens = try tokenizeSource(testing.allocator, "class Point { int x; int y; }");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .class_def);
    try expectEqualStrings("Point", node.class_def.name);
    try expect(node.class_def.parent == null);
    try expectEqual(@as(usize, 2), node.class_def.fields.len);
    try expectEqualStrings("x", node.class_def.fields[0].name);
    try expectEqual(VarType.Int, node.class_def.fields[0].var_type);
    try expectEqualStrings("y", node.class_def.fields[1].name);
    try expectEqual(VarType.Int, node.class_def.fields[1].var_type);
}

test "parser: class with extends" {
    var tokens = try tokenizeSource(testing.allocator, "class Dog extends Animal { }");
    defer freeTokens(&tokens, testing.allocator);

    // 需要先注册父类
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();
    try st.defineClass("Animal", null);

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .class_def);
    try expectEqualStrings("Dog", node.class_def.name);
    try expect(node.class_def.parent != null);
    try expectEqualStrings("Animal", node.class_def.parent.?);
}

test "parser: enum definition" {
    var tokens = try tokenizeSource(testing.allocator, "enum Color { RED, GREEN, BLUE }");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .enum_def);
    try expectEqualStrings("Color", node.enum_def.name);
    try expectEqual(@as(usize, 3), node.enum_def.values.len);
}

test "parser: import statement" {
    var tokens = try tokenizeSource(testing.allocator, "import \"lib.jx\";");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .import_stmt);
    try expectEqualStrings("lib.jx", node.import_stmt);
}

test "parser: new object expression" {
    var tokens = try tokenizeSource(testing.allocator, "new Point()");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    // new 表达式作为表达式语句处理
    try expect(node.* == .expr_stmt);
    try expect(node.expr_stmt.expr.* == .new_object);
    try expectEqualStrings("Point", node.expr_stmt.expr.new_object.class_name);
}

test "parser: string literal expression" {
    var tokens = try tokenizeSource(testing.allocator, "\"hello\";");
    defer freeTokens(&tokens, testing.allocator);

    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    var parser = Parser.init(testing.allocator, tokens.items, &st);
    const node = try parser.parseStatement();
    try expect(node.* == .expr_stmt);
    try expect(node.expr_stmt.expr.* == .string_literal);
    try expectEqualStrings("hello", node.expr_stmt.expr.string_literal);
}
