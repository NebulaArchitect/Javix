// ============================================================
// 文件名: src/compiler_core/codegen.zig
// ============================================================

const std = @import("std");
const Node = @import("ast.zig").Node;
const VarType = @import("ast.zig").VarType;
const SymbolTable = @import("ast.zig").SymbolTable;
const builtins = @import("ast.zig").builtins;

pub const CodeGen = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayListUnmanaged(u8),
    indent: usize,
    sym_table: *SymbolTable,
    in_fn_body: bool = false,

    pub fn init(allocator: std.mem.Allocator, sym_table: *SymbolTable) CodeGen {
        return CodeGen{
            .allocator = allocator,
            .output = .empty,
            .indent = 0,
            .sym_table = sym_table,
        };
    }

    pub fn deinit(self: *CodeGen) void {
        self.output.deinit(self.allocator);
    }

    pub fn generate(self: *CodeGen, ast: *Node) ![]const u8 {
        // 生成 Zig 代码头部 + print 辅助函数 + javax runtime
                try self.output.appendSlice(self.allocator,
            \\const std = @import("std");
            \\const javax = @import("./javax_runtime.zig");
            \\
            \\fn printInt(x: i64) void {
            \\    std.debug.print("{d}\n", .{x});
            \\}
            \\fn printString(s: []const u8) void {
            \\    std.debug.print("{s}\n", .{s});
            \\}
            \\fn printBool(b: bool) void {
            \\    std.debug.print("{}\n", .{b});
            \\}
            \\fn printFloat(x: f64) void {
            \\    std.debug.print("{d}\n", .{x});
            \\}
            \\fn printChar(c: u8) void {
            \\    std.debug.print("{c}\n", .{c});
            \\}
            \\fn arrayLen(arr: anytype) i64 {
            \\    return javax.arrayLen(arr);
            \\}
            \\
        );

        // 生成内置函数 wrapper（thin wrappers → javax.*）
        try self.emitBuiltinWrappers();

        // 第一遍：输出 class/enum 定义和函数定义（放在 main 前面）
        if (ast.* == .block) {
            for (ast.block.statements) |stmt| {
                if (stmt.* == .fn_def or stmt.* == .class_def or stmt.* == .enum_def or stmt.* == .interface_def or stmt.* == .package_stmt) {
                    try self.genNode(stmt);
                    try self.output.appendSlice(self.allocator, "\n");
                }
            }
        }

        // 生成 main 函数（带 arena allocator，供字符串拼接使用）
        try self.output.appendSlice(self.allocator,
            \\pub fn main() !void {
            \\    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            \\    defer arena.deinit();
            \\    const allocator = arena.allocator();
            \\    _ = &allocator; // 无字符串拼接时抑制 unused 警告
            \\
        );
        self.indent += 4;

        // 输出符号表中所有已知变量
        try self.emitSymbolVars();

        // 第二遍：输出非定义类语句（fn_def/class_def/method_def 已在第一遍输出）
        if (ast.* == .block) {
            for (ast.block.statements) |stmt| {
                if (stmt.* != .fn_def and stmt.* != .class_def and stmt.* != .method_def and stmt.* != .enum_def and stmt.* != .interface_def and stmt.* != .package_stmt) {
                    try self.genNode(stmt);
                }
            }
        } else {
            try self.genNode(ast);
        }

        self.indent -= 4;
        try self.output.appendSlice(self.allocator,
            \\}
            \\
        );
        return self.output.items;
    }

    /// 生成内置函数 wrapper（thin wrappers → javax.*）
    fn emitBuiltinWrappers(self: *CodeGen) !void {
        for (builtins) |b| {
            try self.output.appendSlice(self.allocator, "fn ");
            try self.output.appendSlice(self.allocator, b.name);
            try self.output.appendSlice(self.allocator, "(");
            // needs_allocator → 第一个参数是 alloc: std.mem.Allocator
            if (b.needs_allocator) {
                try self.output.appendSlice(self.allocator, "alloc: std.mem.Allocator, ");
            }
            for (b.params, 0..) |param, pi| {
                if (pi > 0) try self.output.appendSlice(self.allocator, ", ");
                try self.output.appendSlice(self.allocator, param.name);
                try self.output.appendSlice(self.allocator, ": ");
                try self.output.appendSlice(self.allocator, self.zigType(param.var_type));
            }
            try self.output.appendSlice(self.allocator, ") ");
            try self.output.appendSlice(self.allocator, self.zigType(b.return_type));
            try self.output.appendSlice(self.allocator, " {\n");
            try self.output.appendSlice(self.allocator, "    return javax.");
            try self.output.appendSlice(self.allocator, b.name);
            try self.output.appendSlice(self.allocator, "(");
            if (b.needs_allocator) {
                try self.output.appendSlice(self.allocator, "alloc, ");
            }
            for (b.params, 0..) |param, pi| {
                if (pi > 0) try self.output.appendSlice(self.allocator, ", ");
                try self.output.appendSlice(self.allocator, param.name);
            }
            // needs_allocator 的函数可能失败（allocator.dupe），加 catch unreachable
            if (b.needs_allocator or b.can_fail) {
                try self.output.appendSlice(self.allocator, ") catch unreachable;\n");
            } else {
                try self.output.appendSlice(self.allocator, ");\n");
            }
            try self.output.appendSlice(self.allocator, "}\n\n");
        }
    }

    /// 查找内置函数定义
    fn lookupBuiltin(name: []const u8) ?@TypeOf(builtins[0]) {
        for (builtins) |b| {
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    /// 输出符号表中所有已知变量（用于跨语句持久化）
    fn emitSymbolVars(self: *CodeGen) !void {
        var it = self.sym_table.symbols.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            const sym = entry.value_ptr.*;
            if (sym.var_type == .Class) {
                const cn = sym.class_name orelse "anyopaque";
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "var ");
                try self.output.appendSlice(self.allocator, name);
                try self.output.appendSlice(self.allocator, ": *");
                try self.output.appendSlice(self.allocator, cn);
                try self.output.appendSlice(self.allocator, " = undefined");
                try self.output.appendSlice(self.allocator, ";\n");
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "_ = &");
                try self.output.appendSlice(self.allocator, name);
                try self.output.appendSlice(self.allocator, ";\n");
                continue;
            }
            const zig_type = switch (sym.var_type) {
                .Int => "i64",
                .Long => "i64",
                .Float => "f32",
                .Double => "f64",
                .Char => "u8",
                .String => "[]const u8",
                .Boolean => "bool",
                .Void => "void",
                .IntArray, .LongArray => "[]i64",
                .DoubleArray => "[]f64",
                .CharArray => "[]u8",
                .StringArray => "[][]const u8",
                .BooleanArray => "[]bool",
                .Class => "*anyopaque",
            };
            const decl_kw = if (sym.modifiers.final) "const" else "var";
            try self.writeIndent();
            try self.output.appendSlice(self.allocator, decl_kw);
            try self.output.appendSlice(self.allocator, " ");
            try self.output.appendSlice(self.allocator, name);
            try self.output.appendSlice(self.allocator, ": ");
            try self.output.appendSlice(self.allocator, zig_type);
            try self.output.appendSlice(self.allocator, " = ");
            switch (sym.var_type) {
                .Int, .Long => try self.output.appendSlice(self.allocator, "0"),
                .Float, .Double => try self.output.appendSlice(self.allocator, "0.0"),
                .Char => try self.output.appendSlice(self.allocator, "0"),
                .String => try self.output.appendSlice(self.allocator, "\"\""),
                .Boolean => try self.output.appendSlice(self.allocator, "false"),
                .Void => try self.output.appendSlice(self.allocator, "{}"),
                .IntArray, .LongArray => try self.output.appendSlice(self.allocator, "&[_]i64{}"),
                .DoubleArray => try self.output.appendSlice(self.allocator, "&[_]f64{}"),
                .CharArray => try self.output.appendSlice(self.allocator, "&[_]u8{}"),
                .StringArray => try self.output.appendSlice(self.allocator, "&[_][]const u8{}"),
                .BooleanArray => try self.output.appendSlice(self.allocator, "&[_]bool{}"),
                .Class => try self.output.appendSlice(self.allocator, "undefined"),
            }
            try self.output.appendSlice(self.allocator, ";\n");
            try self.writeIndent();
            try self.output.appendSlice(self.allocator, "_ = &");
            try self.output.appendSlice(self.allocator, name);
            try self.output.appendSlice(self.allocator, ";\n");
        }
    }

    fn genNode(self: *CodeGen, node: *Node) !void {
        switch (node.*) {
            .if_stmt => |i| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "if (");
                try self.genExpr(i.condition);
                try self.output.appendSlice(self.allocator, ") {\n");
                self.indent += 4;
                try self.genNode(i.then_branch);
                self.indent -= 4;
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "}");
                if (i.else_branch) |else_branch| {
                    try self.output.appendSlice(self.allocator, " else {\n");
                    self.indent += 4;
                    try self.genNode(else_branch);
                    self.indent -= 4;
                    try self.writeIndent();
                    try self.output.appendSlice(self.allocator, "}");
                }
                try self.output.appendSlice(self.allocator, "\n");
            },
            .while_stmt => |w| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "while (");
                try self.genExpr(w.condition);
                try self.output.appendSlice(self.allocator, ") {\n");
                self.indent += 4;
                try self.genNode(w.body);
                self.indent -= 4;
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "}\n");
            },

            .for_stmt => |f| {
                // for (init; cond; update) body → { init; while (cond) : (update) { body } }
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "{\n");
                self.indent += 4;
                // init
                if (f.init) |init_node| {
                    try self.writeIndent();
                    if (init_node.* == .var_decl) {
                        const vd = init_node.var_decl;
                        try self.output.appendSlice(self.allocator, "var ");
                        try self.output.appendSlice(self.allocator, vd.name);
                        try self.output.appendSlice(self.allocator, ": ");
                        try self.output.appendSlice(self.allocator, self.zigType(vd.var_type));
                        if (vd.init) |init_expr| {
                            try self.output.appendSlice(self.allocator, " = ");
                            try self.genExpr(init_expr);
                        }
                        try self.output.appendSlice(self.allocator, ";\n");
                    } else {
                        try self.genExpr(init_node);
                        try self.output.appendSlice(self.allocator, ";\n");
                    }
                }
                // while (cond)
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "while (");
                if (f.condition) |cond| {
                    try self.genExpr(cond);
                } else {
                    try self.output.appendSlice(self.allocator, "true");
                }
                try self.output.appendSlice(self.allocator, ")");
                // update clause
                if (f.update) |update| {
                    try self.output.appendSlice(self.allocator, " : (");
                    try self.genExpr(update);
                    try self.output.appendSlice(self.allocator, ")");
                }
                try self.output.appendSlice(self.allocator, " {\n");
                self.indent += 4;
                try self.genNode(f.body);
                self.indent -= 4;
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "}\n");
                // close scope block
                self.indent -= 4;
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "}\n");
            },

            .do_while_stmt => |dw| {
                // do { body } while (cond) → while (true) { body; if (!cond) break; }
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "while (true) {\n");
                self.indent += 4;
                try self.genNode(dw.body);
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "if (!(");
                try self.genExpr(dw.condition);
                try self.output.appendSlice(self.allocator, ")) break;\n");
                self.indent -= 4;
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "}\n");
            },

            .switch_stmt => |sw| {
                // switch(expr) { case 1,2 => {...}, else => {...} }
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "switch (");
                try self.genExpr(sw.expr);
                try self.output.appendSlice(self.allocator, ") {\n");
                for (sw.cases) |case| {
                    for (case.values, 0..) |val, vi| {
                        if (vi > 0) try self.output.appendSlice(self.allocator, ", ");
                        var buf: [32]u8 = undefined;
                        const s = try std.fmt.bufPrint(&buf, "{d}", .{val});
                        try self.output.appendSlice(self.allocator, s);
                    }
                    try self.output.appendSlice(self.allocator, " => {\n");
                    self.indent += 4;
                    try self.genNode(case.body);
                    self.indent -= 4;
                    try self.writeIndent();
                    try self.output.appendSlice(self.allocator, "},\n");
                }
                if (sw.default_body) |def| {
                    try self.output.appendSlice(self.allocator, "else => {\n");
                    self.indent += 4;
                    try self.genNode(def);
                    self.indent -= 4;
                    try self.writeIndent();
                    try self.output.appendSlice(self.allocator, "},\n");
                } else {
                    // Zig switch 必须穷举，无 default 时加空 else
                    try self.output.appendSlice(self.allocator, "else => {},\n");
                }
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "}\n");
            },

            .var_decl => |vd| {
                if (self.in_fn_body) {
                    // 函数内部：完整声明（局部变量）
                    // final → const，非 final → var（允许后续赋值）
                    const decl_kw = if (vd.modifiers.final) "const" else "var";
                    try self.writeIndent();
                    try self.output.appendSlice(self.allocator, decl_kw);
                    try self.output.appendSlice(self.allocator, " ");
                    try self.output.appendSlice(self.allocator, vd.name);
                    try self.output.appendSlice(self.allocator, ": ");
                    // Class 类型使用具体类名而非 *anyopaque
                    if (vd.var_type == .Class) {
                        const class_name = if (self.sym_table.lookup(vd.name)) |s|
                            s.class_name orelse "anyopaque"
                        else
                            "anyopaque";
                        try self.output.appendSlice(self.allocator, "*");
                        try self.output.appendSlice(self.allocator, class_name);
                    } else {
                        try self.output.appendSlice(self.allocator, self.zigType(vd.var_type));
                    }
                    if (vd.init) |init_expr| {
                        try self.output.appendSlice(self.allocator, " = ");
                        try self.genExpr(init_expr);
                    }
                    try self.output.appendSlice(self.allocator, ";\n");
                    // 抑制 Zig 0.16 "never mutated" 警告
                    if (decl_kw[0] == 'v') { // "var"
                        try self.writeIndent();
                        try self.output.appendSlice(self.allocator, "_ = &");
                        try self.output.appendSlice(self.allocator, vd.name);
                        try self.output.appendSlice(self.allocator, ";\n");
                    }
                } else {
                    // 顶层：emitSymbolVars 已声明，这里仅赋值
                    if (vd.init) |init_expr| {
                        try self.writeIndent();
                        try self.output.appendSlice(self.allocator, vd.name);
                        try self.output.appendSlice(self.allocator, " = ");
                        try self.genExpr(init_expr);
                        try self.output.appendSlice(self.allocator, ";\n");
                    }
                }
            },
            .assign => |a| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, a.name);
                try self.output.appendSlice(self.allocator, " = ");
                try self.genExpr(a.value);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .block => |b| {
                for (b.statements) |stmt| {
                    try self.genNode(stmt);
                }
            },
            .expr_stmt => |e| {
                try self.writeIndent();
                // 如果表达式是函数调用且返回非 void，用 _ = 前缀忽略返回值（Zig 要求使用返回值）
                if (e.expr.* == .call) {
                    const ret_type = self.exprResultType(e.expr);
                    if (ret_type != null and ret_type.? != .Void) {
                        try self.output.appendSlice(self.allocator, "_ = ");
                    }
                }
                try self.genExpr(e.expr);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .fn_def => |f| {
                // 生成 Zig 函数定义
                try self.output.appendSlice(self.allocator, "fn ");
                try self.output.appendSlice(self.allocator, f.name);
                try self.output.appendSlice(self.allocator, "(");
                for (f.params, 0..) |param, pi| {
                    if (pi > 0) try self.output.appendSlice(self.allocator, ", ");
                    try self.output.appendSlice(self.allocator, param.name);
                    try self.output.appendSlice(self.allocator, ": ");
                    try self.output.appendSlice(self.allocator, self.zigType(param.var_type));
                }
                try self.output.appendSlice(self.allocator, ") ");
                try self.output.appendSlice(self.allocator, self.zigType(f.return_type));
                try self.output.appendSlice(self.allocator, " {\n");
                self.indent += 4;
                const prev_in_fn = self.in_fn_body;
                self.in_fn_body = true;
                try self.genNode(f.body);
                self.in_fn_body = prev_in_fn;
                self.indent -= 4;
                try self.output.appendSlice(self.allocator, "}\n");
            },
            .return_stmt => |r| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "return");
                if (r.value) |val| {
                    try self.output.appendSlice(self.allocator, " ");
                    try self.genExpr(val);
                }
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .array_assign => |aa| {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, aa.name);
                try self.output.appendSlice(self.allocator, "[");
                try self.genExpr(aa.index);
                try self.output.appendSlice(self.allocator, "] = ");
                try self.genExpr(aa.value);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            .import_stmt => {}, // 由 compile.zig 预处理，codegen 跳过

            .class_def => |cd| {
                // 生成 Zig struct 定义
                try self.output.appendSlice(self.allocator, "const ");
                try self.output.appendSlice(self.allocator, cd.name);
                try self.output.appendSlice(self.allocator, " = struct {\n");
                // 如果有父类，先输出父类字段
                if (cd.parent) |parent_name| {
                    if (self.sym_table.lookupClass(parent_name)) |pci| {
                        var pit = pci.fields.iterator();
                        while (pit.next()) |pentry| {
                            try self.output.appendSlice(self.allocator, "    ");
                            try self.output.appendSlice(self.allocator, pentry.key_ptr.*);
                            try self.output.appendSlice(self.allocator, ": ");
                            try self.output.appendSlice(self.allocator, self.zigType(pentry.value_ptr.*));
                            try self.output.appendSlice(self.allocator, ",\n");
                        }
                    }
                }
                // 子类字段
                for (cd.fields) |f| {
                    try self.output.appendSlice(self.allocator, "    ");
                    try self.output.appendSlice(self.allocator, f.name);
                    try self.output.appendSlice(self.allocator, ": ");
                    try self.output.appendSlice(self.allocator, self.zigType(f.var_type));
                    try self.output.appendSlice(self.allocator, ",\n");
                }
                try self.output.appendSlice(self.allocator, "};\n\n");
                // 输出方法定义
                for (cd.methods) |m| {
                    try self.genNode(m);
                    try self.output.appendSlice(self.allocator, "\n");
                }
                // 如果有父类，为未重写的父类方法生成 wrapper
                if (cd.parent) |parent_name| {
                    if (self.sym_table.lookupClass(parent_name)) |pci| {
                        var mit = pci.methods.iterator();
                        while (mit.next()) |mentry| {
                            const pmethod = mentry.key_ptr.*;
                            // 检查子类是否重写了该方法
                            var overridden = false;
                            for (cd.methods) |m| {
                                if (m.* == .method_def and std.mem.eql(u8, m.method_def.name, pmethod)) {
                                    overridden = true;
                                    break;
                                }
                            }
                            if (!overridden) {
                                const psig = mentry.value_ptr.*;
                                try self.output.appendSlice(self.allocator, "fn ");
                                try self.output.appendSlice(self.allocator, cd.name);
                                try self.output.appendSlice(self.allocator, "_");
                                try self.output.appendSlice(self.allocator, pmethod);
                                try self.output.appendSlice(self.allocator, "(self: *");
                                try self.output.appendSlice(self.allocator, cd.name);
                                for (psig.params) |p| {
                                    try self.output.appendSlice(self.allocator, ", ");
                                    try self.output.appendSlice(self.allocator, p.name);
                                    try self.output.appendSlice(self.allocator, ": ");
                                    try self.output.appendSlice(self.allocator, self.zigType(p.var_type));
                                }
                                try self.output.appendSlice(self.allocator, ") ");
                                try self.output.appendSlice(self.allocator, self.zigType(psig.return_type));
                                try self.output.appendSlice(self.allocator, " {\n");
                                try self.output.appendSlice(self.allocator, "    return ");
                                try self.output.appendSlice(self.allocator, parent_name);
                                try self.output.appendSlice(self.allocator, "_");
                                try self.output.appendSlice(self.allocator, pmethod);
                                try self.output.appendSlice(self.allocator, "(@ptrCast(self)");
                                for (psig.params) |p| {
                                    try self.output.appendSlice(self.allocator, ", ");
                                    try self.output.appendSlice(self.allocator, p.name);
                                }
                                try self.output.appendSlice(self.allocator, ");\n");
                                try self.output.appendSlice(self.allocator, "}\n\n");
                            }
                        }
                    }
                }
            },
            .method_def => |md| {
                // 方法生成为 ClassName_methodName(self: *ClassName, ...)
                try self.output.appendSlice(self.allocator, "fn ");
                try self.output.appendSlice(self.allocator, md.class_name);
                try self.output.appendSlice(self.allocator, "_");
                try self.output.appendSlice(self.allocator, md.name);
                try self.output.appendSlice(self.allocator, "(");
                var first_param = true;
                if (!md.modifiers.static) {
                    try self.output.appendSlice(self.allocator, "self: *");
                    try self.output.appendSlice(self.allocator, md.class_name);
                    first_param = false;
                }
                for (md.params) |p| {
                    if (!first_param) {
                        try self.output.appendSlice(self.allocator, ", ");
                    }
                    try self.output.appendSlice(self.allocator, p.name);
                    try self.output.appendSlice(self.allocator, ": ");
                    try self.output.appendSlice(self.allocator, self.zigType(p.var_type));
                    first_param = false;
                }
                try self.output.appendSlice(self.allocator, ") ");
                try self.output.appendSlice(self.allocator, self.zigType(md.return_type));
                try self.output.appendSlice(self.allocator, " {\n");
                self.indent += 4;
                const prev_in_fn = self.in_fn_body;
                self.in_fn_body = true;
                if (md.is_abstract) {
                    try self.writeIndent();
                    try self.output.appendSlice(self.allocator, "_ = self;\n");
                    try self.writeIndent();
                    try self.output.appendSlice(self.allocator, "@panic(\"abstract method\");\n");
                } else {
                    if (!md.modifiers.static) {
                        try self.writeIndent();
                        try self.output.appendSlice(self.allocator, "_ = self;\n");
                    }
                    try self.genNode(md.body);
                }
                self.in_fn_body = prev_in_fn;
                self.indent -= 4;
                try self.output.appendSlice(self.allocator, "}\n\n");
            },
            .field => {}, // 不在 genNode 单独处理，由 class_def 统一生成
            .enum_def => |ed| {
                try self.output.appendSlice(self.allocator, "const ");
                try self.output.appendSlice(self.allocator, ed.name);
                try self.output.appendSlice(self.allocator, " = enum { ");
                for (ed.values, 0..) |val, i| {
                    if (i > 0) try self.output.appendSlice(self.allocator, ", ");
                    try self.output.appendSlice(self.allocator, val);
                }
                try self.output.appendSlice(self.allocator, " };\n\n");
            },
            .interface_def => |iface| {
                // 接口: 生成 struct + 抽象方法占位
                try self.output.appendSlice(self.allocator, "const ");
                try self.output.appendSlice(self.allocator, iface.name);
                try self.output.appendSlice(self.allocator, " = struct {};\n\n");
                for (iface.methods) |m| {
                    try self.genNode(m);
                    try self.output.appendSlice(self.allocator, "\n");
                }
            },
            .package_stmt => {
                // 包声明仅语法支持，不影响代码生成
            },
            .member_assign => |ma| {
                try self.writeIndent();
                try self.genExpr(ma.object);
                try self.output.appendSlice(self.allocator, ".");
                try self.output.appendSlice(self.allocator, ma.member);
                try self.output.appendSlice(self.allocator, " = ");
                try self.genExpr(ma.value);
                try self.output.appendSlice(self.allocator, ";\n");
            },
            else => {
                try self.writeIndent();
                try self.output.appendSlice(self.allocator, "// unsupported: ");
                try self.output.appendSlice(self.allocator, @tagName(node.*));
                try self.output.appendSlice(self.allocator, "\n");
            },
        }
    }

    fn genExpr(self: *CodeGen, node: *Node) !void {
        switch (node.*) {
            .int_literal => |v| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
                try self.output.appendSlice(self.allocator, s);
            },
            .long_literal => |v| {
                var buf: [32]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
                try self.output.appendSlice(self.allocator, s);
            },
            .float_literal => |v| {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
                try self.output.appendSlice(self.allocator, s);
            },
            .double_literal => |v| {
                var buf: [64]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
                try self.output.appendSlice(self.allocator, s);
            },
            .char_literal => |c| {
                var buf: [8]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{c});
                try self.output.appendSlice(self.allocator, s);
            },
            .string_literal => |s| {
                try self.output.appendSlice(self.allocator, "\"");
                try self.escapeAndEmit(s);
                try self.output.appendSlice(self.allocator, "\"");
            },
            .boolean_literal => |b| {
                try self.output.appendSlice(self.allocator, if (b) "true" else "false");
            },
            .identifier => |id| {
                try self.output.appendSlice(self.allocator, id);
            },
            .binary => |bin| {
                // 字符串拼接：两端都是 String 时用 std.mem.concat
                if (bin.op == .add and
                    self.exprResultType(bin.left) == .String and
                    self.exprResultType(bin.right) == .String)
                {
                    try self.output.appendSlice(self.allocator, "try std.mem.concat(allocator, u8, &[_][]const u8{ ");
                    try self.genExpr(bin.left);
                    try self.output.appendSlice(self.allocator, ", ");
                    try self.genExpr(bin.right);
                    try self.output.appendSlice(self.allocator, " })");
                } else {
                    try self.output.appendSlice(self.allocator, "(");
                    try self.genExpr(bin.left);
                    try self.output.appendSlice(self.allocator, " ");
                    switch (bin.op) {
                        .add => try self.output.appendSlice(self.allocator, "+"),
                        .sub => try self.output.appendSlice(self.allocator, "-"),
                        .mul => try self.output.appendSlice(self.allocator, "*"),
                        .div => try self.output.appendSlice(self.allocator, "/"),
                        .mod => try self.output.appendSlice(self.allocator, "%"),
                        .eq => try self.output.appendSlice(self.allocator, "=="),
                        .neq => try self.output.appendSlice(self.allocator, "!="),
                        .lt => try self.output.appendSlice(self.allocator, "<"),
                        .gt => try self.output.appendSlice(self.allocator, ">"),
                        .le => try self.output.appendSlice(self.allocator, "<="),
                        .ge => try self.output.appendSlice(self.allocator, ">="),
                        .bool_and => try self.output.appendSlice(self.allocator, " and "),
                        .bool_or => try self.output.appendSlice(self.allocator, " or "),
                    }
                    try self.output.appendSlice(self.allocator, " ");
                    try self.genExpr(bin.right);
                    try self.output.appendSlice(self.allocator, ")");
                }
            },
            .unary => |u| {
                try self.output.appendSlice(self.allocator, "(-");
                try self.genExpr(u.expr);
                try self.output.appendSlice(self.allocator, ")");
            },
            .call => |c| {
                if (std.mem.eql(u8, c.callee, "print") and c.args.len == 1) {
                    const arg = c.args[0];
                    const arg_type = self.exprResultType(arg) orelse .Int;
                    const func_name = switch (arg_type) {
                        .Int, .Long => "printInt",
                        .Float, .Double => "printFloat",
                        .Char => "printChar",
                        .String => "printString",
                        .Boolean => "printBool",
                        .Void => "printInt",
                        .IntArray, .LongArray, .DoubleArray, .CharArray, .StringArray, .BooleanArray => "printInt",
                        .Class => "printInt",
                    };
                    try self.output.appendSlice(self.allocator, func_name);
                    try self.output.appendSlice(self.allocator, "(");
                    // f32 需要显式转为 f64 才能传给 printFloat
                    if (arg_type == .Float) {
                        try self.output.appendSlice(self.allocator, "@as(f64, ");
                        try self.genExpr(arg);
                        try self.output.appendSlice(self.allocator, ")");
                    } else {
                        try self.genExpr(arg);
                    }
                    try self.output.appendSlice(self.allocator, ")");
                } else if (lookupBuiltin(c.callee)) |builtin| {
                    // 内置函数调用：需要 allocator 则自动注入
                    try self.output.appendSlice(self.allocator, c.callee);
                    try self.output.appendSlice(self.allocator, "(");
                    if (builtin.needs_allocator) {
                        const alloc_ref = if (self.in_fn_body) "std.heap.page_allocator" else "allocator";
                        try self.output.appendSlice(self.allocator, alloc_ref);
                        try self.output.appendSlice(self.allocator, ", ");
                    }
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try self.output.appendSlice(self.allocator, ", ");
                        try self.genExpr(arg);
                    }
                    try self.output.appendSlice(self.allocator, ")");
                } else {
                    try self.output.appendSlice(self.allocator, c.callee);
                    try self.output.appendSlice(self.allocator, "(");
                    for (c.args, 0..) |arg, i| {
                        if (i > 0) try self.output.appendSlice(self.allocator, ", ");
                        try self.genExpr(arg);
                    }
                    try self.output.appendSlice(self.allocator, ")");
                }
            },
            .new_object => |no| {
                // new Point(a, b) → alloc + field assignments from class field order
                // 函数内部没有 allocator，使用 page_allocator（TODO: 统一 allocator 传递）
                const alloc_ref = if (self.in_fn_body) "std.heap.page_allocator" else "allocator";
                if (no.args.len > 0) {
                    try self.output.appendSlice(self.allocator, "blk: { const _obj = ");
                    try self.output.appendSlice(self.allocator, alloc_ref);
                    try self.output.appendSlice(self.allocator, ".create(");
                    try self.output.appendSlice(self.allocator, no.class_name);
                    try self.output.appendSlice(self.allocator, ") catch unreachable; ");
                    // 按父类→子类顺序分配字段
                    if (self.sym_table.lookupClass(no.class_name)) |ci| {
                        var fi: usize = 0;
                        // 先处理父类字段
                        if (ci.parent) |pname| {
                            if (self.sym_table.lookupClass(pname)) |pci| {
                                var pit = pci.fields.iterator();
                                while (pit.next()) |pentry| : (fi += 1) {
                                    if (fi >= no.args.len) break;
                                    try self.output.appendSlice(self.allocator, "_obj.");
                                    try self.output.appendSlice(self.allocator, pentry.key_ptr.*);
                                    try self.output.appendSlice(self.allocator, " = ");
                                    try self.genExpr(no.args[fi]);
                                    try self.output.appendSlice(self.allocator, "; ");
                                }
                            }
                        }
                        // 再处理子类字段
                        var it = ci.fields.iterator();
                        while (it.next()) |entry| : (fi += 1) {
                            if (fi >= no.args.len) break;
                            try self.output.appendSlice(self.allocator, "_obj.");
                            try self.output.appendSlice(self.allocator, entry.key_ptr.*);
                            try self.output.appendSlice(self.allocator, " = ");
                            try self.genExpr(no.args[fi]);
                            try self.output.appendSlice(self.allocator, "; ");
                        }
                    }
                    try self.output.appendSlice(self.allocator, "break :blk _obj; }");
                } else {
                    try self.output.appendSlice(self.allocator, alloc_ref);
                    try self.output.appendSlice(self.allocator, ".create(");
                    try self.output.appendSlice(self.allocator, no.class_name);
                    try self.output.appendSlice(self.allocator, ") catch unreachable");
                }
            },
            .member_access => |ma| {
                // p.x → p.x, p.method() → handled in primary parsing
                try self.genExpr(ma.object);
                try self.output.appendSlice(self.allocator, ".");
                try self.output.appendSlice(self.allocator, ma.member);
            },
            .this_expr => {
                try self.output.appendSlice(self.allocator, "self");
            },
            .field => |f| {
                // should not normally reach here
                try self.output.appendSlice(self.allocator, f.name);
            },
            .new_array => |na| {
                // 生成 allocator.alloc(type, size)
                try self.output.appendSlice(self.allocator, "try allocator.alloc(");
                try self.output.appendSlice(self.allocator, self.zigType(na.elem_type));
                try self.output.appendSlice(self.allocator, ", @intCast(");
                try self.genExpr(na.size);
                try self.output.appendSlice(self.allocator, "))");
            },
            .array_access => |aa| {
                try self.genExpr(aa.array);
                try self.output.appendSlice(self.allocator, "[@intCast(");
                try self.genExpr(aa.index);
                try self.output.appendSlice(self.allocator, ")]");
            },
            .assign => |a| {
                // 表达式级赋值（用于 for-update 等场景）
                try self.output.appendSlice(self.allocator, a.name);
                try self.output.appendSlice(self.allocator, " = ");
                try self.genExpr(a.value);
            },
            else => {
                try self.output.appendSlice(self.allocator, "0");
            },
        }
    }

    fn writeIndent(self: *CodeGen) !void {
        for (0..self.indent) |_| {
            try self.output.appendSlice(self.allocator, " ");
        }
    }

    /// 对字符串进行 Zig 转义（处理 "、\、换行等）
    fn escapeAndEmit(self: *CodeGen, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '\n' => try self.output.appendSlice(self.allocator, "\\n"),
                '\r' => try self.output.appendSlice(self.allocator, "\\r"),
                '\t' => try self.output.appendSlice(self.allocator, "\\t"),
                '"' => try self.output.appendSlice(self.allocator, "\\\""),
                '\\' => try self.output.appendSlice(self.allocator, "\\\\"),
                else => try self.output.append(self.allocator, c),
            }
        }
    }

    fn zigType(self: *CodeGen, vt: VarType) []const u8 {
        _ = self;
        return switch (vt) {
            .Int => "i64",
            .Long => "i64",
            .Float => "f32",
            .Double => "f64",
            .Char => "u8",
            .String => "[]const u8",
            .Boolean => "bool",
            .Void => "void",
            .IntArray, .LongArray => "[]i64",
            .DoubleArray => "[]f64",
            .CharArray => "[]u8",
            .StringArray => "[][]const u8",
            .BooleanArray => "[]bool",
            .Class => "*anyopaque",
        };
    }

    /// 推断表达式的返回值类型（用于 print 分发和字符串拼接检测）
    fn exprResultType(self: *CodeGen, node: *Node) ?VarType {
        return switch (node.*) {
            .int_literal => .Int,
            .long_literal => .Long,
            .float_literal => .Float,
            .double_literal => .Double,
            .char_literal => .Char,
            .string_literal => .String,
            .boolean_literal => .Boolean,
            .identifier => |id| {
                if (self.sym_table.lookup(id)) |sym| return sym.var_type;
                return null;
            },
            .binary => |b| switch (b.op) {
                .add => {
                    const lt = self.exprResultType(b.left);
                    const rt = self.exprResultType(b.right);
                    if (lt != null and rt != null and lt == rt) return lt;
                    return null;
                },
                .eq, .neq, .lt, .gt, .le, .ge, .bool_and, .bool_or => .Boolean,
                else => .Int,
            },
            .unary => |u| self.exprResultType(u.expr),
            .call => |c| {
                if (self.sym_table.lookupFn(c.callee)) |fsig| return fsig.return_type;
                return null;
            },
            .new_array => |na| na.elem_type.toArray(),
            .array_access => |aa| {
                const arr_type = self.exprResultType(aa.array) orelse return null;
                return arr_type.elemType();
            },
            .member_access => |ma| {
                if (ma.object.* == .identifier) {
                    if (self.sym_table.lookup(ma.object.identifier)) |sym| {
                        if (sym.class_name) |cn| {
                            return self.sym_table.lookupClassField(cn, ma.member);
                        }
                    }
                }
                return null;
            },
            else => null,
        };
    }
};
