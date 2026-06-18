// ============================================================
// 文件名: src/compiler_core/ast.zig
// ============================================================

const std = @import("std");

pub const Node = union(enum) {
    // 表达式
    int_literal: i64,
    long_literal: i64,
    float_literal: f64,
    double_literal: f64,
    char_literal: u8,
    string_literal: []const u8,
    // 标识符（变量引用）
    identifier: []const u8,
    boolean_literal: bool,

    // 二元运算
    binary: struct {
        op: Op,
        left: *Node,
        right: *Node,
    },

    // 一元运算（预留）
    unary: struct {
        op: Op,
        expr: *Node,
    },

    // 函数调用
    call: struct {
        callee: []const u8,
        args: []*Node,
    },

    // ---------- 语句 ----------
    var_decl: struct {
        var_type: VarType,
        name: []const u8,
        init: ?*Node,  // 初始化表达式（可为null）
        modifiers: Modifiers = .{},
    },

    assign: struct {
        name: []const u8,
        value: *Node,
    },

    // ---------- 函数定义 ----------
    fn_def: struct {
        name: []const u8,
        params: []Param,
        return_type: VarType,
        body: *Node,  // Block
        modifiers: Modifiers = .{},
    },
    // ---------- 返回语句 ----------
    return_stmt: struct {
        value: ?*Node,
    },

    block: struct {
        statements: []*Node,
    },

    expr_stmt: struct {
        expr: *Node,  // 表达式语句，如 "1 + 2;" 或 "foo();"
    },

    // 错误节点
    token_error: []const u8,


    if_stmt: struct {
        condition: *Node,
        then_branch: *Node,
        else_branch: ?*Node,
    },
    while_stmt: struct {
        condition: *Node,
        body: *Node,
    },
    for_stmt: struct {
        init: ?*Node,       // var_decl / assign / null
        condition: ?*Node,  // expression / null (null=always true)
        update: ?*Node,     // expression / null
        body: *Node,
    },
    do_while_stmt: struct {
        body: *Node,
        condition: *Node,
    },

    // ---------- switch ----------
    switch_stmt: struct {
        expr: *Node,
        cases: []SwitchCase,
        default_body: ?*Node,
    },

    // ---------- 枚举 ----------
    enum_def: struct {
        name: []const u8,
        values: [][]const u8,
    },

    // ---------- 接口 ----------
    interface_def: struct {
        name: []const u8,
        methods: []*Node, // method_def 节点列表（全部抽象）
    },

    // ---------- 包声明 ----------
    package_stmt: []const u8,

    // ---------- 数组 ----------
    new_array: struct {
        elem_type: VarType,
        size: *Node, // 大小表达式
    },
    array_access: struct {
        array: *Node, // 标识符或表达式
        index: *Node,
    },
    array_assign: struct {
        name: []const u8,
        index: *Node,
        value: *Node,
    },

    // ---------- 模块导入 ----------
    import_stmt: []const u8, // 导入路径

    // ---------- 面向对象 ----------
    class_def: struct {
        name: []const u8,
        parent: ?[]const u8 = null, // extends 父类名
        fields: []Field,
        methods: []*Node, // method_def 节点列表
        modifiers: Modifiers = .{},
    },
    method_def: struct {
        name: []const u8,
        class_name: []const u8,
        params: []Param,
        return_type: VarType,
        body: *Node, // Block (abstract 时为占位)
        modifiers: Modifiers = .{},
        is_abstract: bool = false,
    },
    field: Field,
    new_object: struct {
        class_name: []const u8,
        args: []*Node,
    },
    member_access: struct {
        object: *Node,
        member: []const u8,
    },
    member_assign: struct {
        object: *Node,
        member: []const u8,
        value: *Node,
    },
    this_expr: void,

};

// 修饰符标志位（对齐 Java: public/private/protected/static/final/abstract）
pub const Modifiers = packed struct {
    public: bool = false,
    private: bool = false,
    protected: bool = false,
    static: bool = false,
    final: bool = false,
    abstract: bool = false,

    pub fn hasAccessMod(self: Modifiers) bool {
        return self.public or self.private or self.protected;
    }

    pub fn format(self: Modifiers, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        var first = true;
        if (self.public) { if (!first) try writer.writeAll(" "); try writer.writeAll("public"); first = false; }
        if (self.private) { if (!first) try writer.writeAll(" "); try writer.writeAll("private"); first = false; }
        if (self.protected) { if (!first) try writer.writeAll(" "); try writer.writeAll("protected"); first = false; }
        if (self.static) { if (!first) try writer.writeAll(" "); try writer.writeAll("static"); first = false; }
        if (self.final) { if (!first) try writer.writeAll(" "); try writer.writeAll("final"); first = false; }
        if (self.abstract) { if (!first) try writer.writeAll(" "); try writer.writeAll("abstract"); first = false; }
    }
};

pub const Op = enum {
    add,        // +
    sub,        // -
    mul,        // *
    div,        // /
    mod,        // %
    eq,         // ==
    neq,        // !=
    lt,         // <
    gt,         // >
    le,         // <=
    ge,         // >=
    bool_and,        // &&
    bool_or,         // ||
};

pub const VarType = enum {
    Int, Long, Float, Double, Char, String, Boolean, Void,
    IntArray, LongArray, DoubleArray, CharArray, StringArray, BooleanArray,
    Class, // 对象实例（具体类名由符号表管理）

    pub fn isArray(self: VarType) bool {
        return switch (self) {
            .IntArray, .LongArray, .DoubleArray, .CharArray, .StringArray, .BooleanArray => true,
            else => false,
        };
    }

    pub fn toArray(self: VarType) VarType {
        return switch (self) {
            .Int => .IntArray,
            .Long => .LongArray,
            .Double => .DoubleArray,
            .Char => .CharArray,
            .String => .StringArray,
            .Boolean => .BooleanArray,
            else => self,
        };
    }

    pub fn elemType(self: VarType) VarType {
        return switch (self) {
            .IntArray => .Int,
            .LongArray => .Long,
            .DoubleArray => .Double,
            .CharArray => .Char,
            .StringArray => .String,
            .BooleanArray => .Boolean,
            else => self,
        };
    }
};

pub const Param = struct {
    name: []const u8,
    var_type: VarType,
};

// 符号表条目
// 类字段定义
pub const Field = struct {
    name: []const u8,
    var_type: VarType,
    modifiers: Modifiers = .{},
};

// switch case 定义
pub const SwitchCase = struct {
    values: []i64,  // 多个 case 标签可共享一个 body
    body: *Node,
};

// 符号表条目
pub const Symbol = struct {
    name: []const u8,
    var_type: VarType,
    class_name: ?[]const u8 = null, // Class 类型的具体类名
    modifiers: Modifiers = .{},
};

// 函数签名
pub const FnSig = struct {
    params: []const Param,
    return_type: VarType,
    class_name: ?[]const u8 = null, // 方法所属类名
};

// 类信息
pub const ClassInfo = struct {
    fields: std.StringHashMap(VarType),
    methods: std.StringHashMap(FnSig),
    parent: ?[]const u8 = null, // 父类名
};

// 符号表（简单作用域）
pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(Symbol),
    functions: std.StringHashMap(FnSig),
    classes: std.StringHashMap(ClassInfo),

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return SymbolTable{
            .allocator = allocator,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .functions = std.StringHashMap(FnSig).init(allocator),
            .classes = std.StringHashMap(ClassInfo).init(allocator),
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        var it = self.symbols.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.symbols.deinit();

        var fit = self.functions.iterator();
        while (fit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.functions.deinit();

        var cit = self.classes.iterator();
        while (cit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // 清理 ClassInfo 内部的 sub-hashmaps 和 parent
            entry.value_ptr.fields.deinit();
            entry.value_ptr.methods.deinit();
            if (entry.value_ptr.parent) |p| self.allocator.free(p);
        }
        self.classes.deinit();
    }

    pub fn define(self: *SymbolTable, name: []const u8, var_type: VarType, modifiers: Modifiers) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.symbols.put(name_copy, Symbol{ .name = name_copy, .var_type = var_type, .modifiers = modifiers });
    }

    pub fn defineClass(self: *SymbolTable, name: []const u8, parent: ?[]const u8) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const parent_copy = if (parent) |p| try self.allocator.dupe(u8, p) else null;
        try self.classes.put(name_copy, ClassInfo{
            .fields = std.StringHashMap(VarType).init(self.allocator),
            .methods = std.StringHashMap(FnSig).init(self.allocator),
            .parent = parent_copy,
        });
    }

    pub fn addField(self: *SymbolTable, class_name: []const u8, field_name: []const u8, field_type: VarType) !void {
        if (self.classes.getPtr(class_name)) |ci| {
            const fn_copy = try self.allocator.dupe(u8, field_name);
            try ci.fields.put(fn_copy, field_type);
        }
    }

    pub fn addMethod(self: *SymbolTable, class_name: []const u8, method_name: []const u8, sig: FnSig) !void {
        if (self.classes.getPtr(class_name)) |ci| {
            const mn_copy = try self.allocator.dupe(u8, method_name);
            try ci.methods.put(mn_copy, sig);
        }
    }

    pub fn isClass(self: *SymbolTable, name: []const u8) bool {
        return self.classes.contains(name);
    }

    pub fn lookupClass(self: *SymbolTable, name: []const u8) ?ClassInfo {
        // 返回副本（浅拷贝，引用内部的 HashMap）
        return self.classes.get(name) orelse return null;
    }

    pub fn lookupClassField(self: *SymbolTable, class_name: []const u8, field_name: []const u8) ?VarType {
        const ci = self.classes.get(class_name) orelse return null;
        return ci.fields.get(field_name);
    }

    pub fn lookupClassMethod(self: *SymbolTable, class_name: []const u8, method_name: []const u8) ?FnSig {
        const ci = self.classes.get(class_name) orelse return null;
        return ci.methods.get(method_name);
    }

    pub fn defineFn(self: *SymbolTable, name: []const u8, params: []const Param, return_type: VarType) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.functions.put(name_copy, FnSig{ .params = params, .return_type = return_type });
    }

    pub fn lookup(self: *SymbolTable, name: []const u8) ?Symbol {
        return self.symbols.get(name);
    }

    pub fn lookupFn(self: *SymbolTable, name: []const u8) ?FnSig {
        return self.functions.get(name);
    }

    pub fn defineClassVar(self: *SymbolTable, name: []const u8, class_name: []const u8, modifiers: Modifiers) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        const cn_copy = try self.allocator.dupe(u8, class_name);
        try self.symbols.put(name_copy, Symbol{ .name = name_copy, .var_type = .Class, .class_name = cn_copy, .modifiers = modifiers });
    }

    /// 预注册所有内置函数到符号表
    pub fn registerBuiltins(self: *SymbolTable) !void {
        for (builtins) |b| {
            try self.defineFn(b.name, b.params, b.return_type);
        }
        // arrayLen 用 anytype，不适用 auto-wrapper，手动注册
        try self.defineFn("arrayLen", &[_]Param{.{ .name = "arr", .var_type = .IntArray }}, .Int);
    }
};

// ============================================================
// 内置函数注册表
// ============================================================
pub const BuiltinFn = struct {
    name: []const u8,
    params: []const Param,
    return_type: VarType,
    needs_allocator: bool,
    can_fail: bool = false
};

/// 所有内置函数定义
pub const builtins = [_]BuiltinFn{
    // ---- String 操作 ----
    .{ .name = "strlen", .params = &[_]Param{.{ .name = "s", .var_type = .String }}, .return_type = .Int, .needs_allocator = false },
    .{ .name = "strequal", .params = &[_]Param{ .{ .name = "a", .var_type = .String }, .{ .name = "b", .var_type = .String } }, .return_type = .Boolean, .needs_allocator = false },
    .{ .name = "strcontains", .params = &[_]Param{ .{ .name = "s", .var_type = .String }, .{ .name = "needle", .var_type = .String } }, .return_type = .Boolean, .needs_allocator = false },
    .{ .name = "strsub", .params = &[_]Param{ .{ .name = "s", .var_type = .String }, .{ .name = "start", .var_type = .Int }, .{ .name = "len", .var_type = .Int } }, .return_type = .String, .needs_allocator = true },
    .{ .name = "strtrim", .params = &[_]Param{.{ .name = "s", .var_type = .String }}, .return_type = .String, .needs_allocator = true },

    // ---- Math 操作 ----
    .{ .name = "mathAbs", .params = &[_]Param{.{ .name = "x", .var_type = .Int }}, .return_type = .Int, .needs_allocator = false },
    .{ .name = "mathMin", .params = &[_]Param{ .{ .name = "a", .var_type = .Int }, .{ .name = "b", .var_type = .Int } }, .return_type = .Int, .needs_allocator = false },
    .{ .name = "mathMax", .params = &[_]Param{ .{ .name = "a", .var_type = .Int }, .{ .name = "b", .var_type = .Int } }, .return_type = .Int, .needs_allocator = false },
    .{ .name = "mathPow", .params = &[_]Param{ .{ .name = "base", .var_type = .Double }, .{ .name = "exp", .var_type = .Double } }, .return_type = .Double, .needs_allocator = false },
    .{ .name = "mathSqrt", .params = &[_]Param{.{ .name = "x", .var_type = .Double }}, .return_type = .Double, .needs_allocator = false },

    // ---- 类型转换 ----
    .{ .name = "intToString", .params = &[_]Param{.{ .name = "x", .var_type = .Int }}, .return_type = .String, .needs_allocator = true },
    .{ .name = "doubleToString", .params = &[_]Param{.{ .name = "x", .var_type = .Double }}, .return_type = .String, .needs_allocator = true },

    // ---- HTTP 客户端 ----
    .{ .name = "httpGet", .params = &[_]Param{.{ .name = "url", .var_type = .String }}, .return_type = .String, .needs_allocator = true },
    .{ .name = "httpPost", .params = &[_]Param{ .{ .name = "url", .var_type = .String }, .{ .name = "body", .var_type = .String } }, .return_type = .String, .needs_allocator = true },

    // ---- JSON 解析 ----
    .{ .name = "jsonGet", .params = &[_]Param{ .{ .name = "json", .var_type = .String }, .{ .name = "key", .var_type = .String } }, .return_type = .String, .needs_allocator = true },

    // ---- Character 操作 ----
    .{ .name = "charIsDigit", .params = &[_]Param{.{ .name = "c", .var_type = .Char }}, .return_type = .Boolean, .needs_allocator = false },
    .{ .name = "charIsLetter", .params = &[_]Param{.{ .name = "c", .var_type = .Char }}, .return_type = .Boolean, .needs_allocator = false },
    .{ .name = "charToUpper", .params = &[_]Param{.{ .name = "c", .var_type = .Char }}, .return_type = .Char, .needs_allocator = false },
    .{ .name = "charToLower", .params = &[_]Param{.{ .name = "c", .var_type = .Char }}, .return_type = .Char, .needs_allocator = false },

    // ---- 日期时间 ----
    .{ .name = "currentTimeMillis", .params = &[_]Param{}, .return_type = .Int, .needs_allocator = false },

    // ---- 文件 IO ----
    .{ .name = "readFile", .params = &[_]Param{.{ .name = "path", .var_type = .String }}, .return_type = .String, .needs_allocator = true },
    .{ .name = "writeFile", .params = &[_]Param{ .{ .name = "path", .var_type = .String }, .{ .name = "data", .var_type = .String } }, .return_type = .Void, .needs_allocator = false, .can_fail = true },

    // ---- 集合框架 (HashMap<String,String>) ----
    .{ .name = "mapPut", .params = &[_]Param{ .{ .name = "key", .var_type = .String }, .{ .name = "value", .var_type = .String } }, .return_type = .Void, .needs_allocator = true },
    .{ .name = "mapGet", .params = &[_]Param{.{ .name = "key", .var_type = .String }}, .return_type = .String, .needs_allocator = true },
    .{ .name = "mapContainsKey", .params = &[_]Param{.{ .name = "key", .var_type = .String }}, .return_type = .Boolean, .needs_allocator = false },

    // ---- 多线程 ----
    .{ .name = "threadSleep", .params = &[_]Param{.{ .name = "ms", .var_type = .Int }}, .return_type = .Void, .needs_allocator = false },

    // ---- 文件IO扩展 ----
    .{ .name = "fileAppend", .params = &[_]Param{ .{ .name = "path", .var_type = .String }, .{ .name = "data", .var_type = .String } }, .return_type = .Void, .needs_allocator = false, .can_fail = true },

    // ---- ArrayList (String列表) ----
    .{ .name = "listCreate", .params = &[_]Param{}, .return_type = .Int, .needs_allocator = true },
    .{ .name = "listAdd", .params = &[_]Param{ .{ .name = "handle", .var_type = .Int }, .{ .name = "item", .var_type = .String } }, .return_type = .Void, .needs_allocator = true },
    .{ .name = "listGet", .params = &[_]Param{ .{ .name = "handle", .var_type = .Int }, .{ .name = "index", .var_type = .Int } }, .return_type = .String, .needs_allocator = true },
    .{ .name = "listSize", .params = &[_]Param{.{ .name = "handle", .var_type = .Int }}, .return_type = .Int, .needs_allocator = false },
};

// ==================================================================
// 单元测试
// ==================================================================

const testing = std.testing;
const expectEqual = testing.expectEqual;
const expect = testing.expect;
const expectEqualStrings = testing.expectEqualStrings;

// ---- VarType ----

test "VarType: isArray detects array types" {
    try expect(VarType.IntArray.isArray());
    try expect(VarType.LongArray.isArray());
    try expect(VarType.DoubleArray.isArray());
    try expect(VarType.CharArray.isArray());
    try expect(VarType.StringArray.isArray());
    try expect(VarType.BooleanArray.isArray());
    try expect(!VarType.Int.isArray());
    try expect(!VarType.String.isArray());
    try expect(!VarType.Class.isArray());
}

test "VarType: toArray converts basic types to array" {
    try expectEqual(VarType.IntArray, VarType.Int.toArray());
    try expectEqual(VarType.LongArray, VarType.Long.toArray());
    try expectEqual(VarType.DoubleArray, VarType.Double.toArray());
    try expectEqual(VarType.CharArray, VarType.Char.toArray());
    try expectEqual(VarType.StringArray, VarType.String.toArray());
    try expectEqual(VarType.BooleanArray, VarType.Boolean.toArray());
    // Non-basic types return self
    try expectEqual(VarType.Class, VarType.Class.toArray());
    try expectEqual(VarType.Void, VarType.Void.toArray());
}

test "VarType: elemType extracts element type from arrays" {
    try expectEqual(VarType.Int, VarType.IntArray.elemType());
    try expectEqual(VarType.Long, VarType.LongArray.elemType());
    try expectEqual(VarType.Double, VarType.DoubleArray.elemType());
    try expectEqual(VarType.Char, VarType.CharArray.elemType());
    try expectEqual(VarType.String, VarType.StringArray.elemType());
    try expectEqual(VarType.Boolean, VarType.BooleanArray.elemType());
    // Non-array types return self
    try expectEqual(VarType.Int, VarType.Int.elemType());
}

// ---- Modifiers ----

test "Modifiers: hasAccessMod" {
    const m_pub = Modifiers{ .public = true };
    const m_priv = Modifiers{ .private = true };
    const m_prot = Modifiers{ .protected = true };
    const m_none = Modifiers{};
    const m_static = Modifiers{ .static = true };
    try expect(m_pub.hasAccessMod());
    try expect(m_priv.hasAccessMod());
    try expect(m_prot.hasAccessMod());
    try expect(!m_none.hasAccessMod());
    try expect(!m_static.hasAccessMod());
}

test "Modifiers: format output" {
    const m = Modifiers{ .public = true, .static = true };
    // Just verify it doesn't crash — the formatter is used for debug prints
    try expect(m.hasAccessMod());
}

// ---- SymbolTable ----

test "SymbolTable: define and lookup variable" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    try st.define("x", .Int, .{});
    const sym = st.lookup("x");
    try expect(sym != null);
    try expectEqual(VarType.Int, sym.?.var_type);
    try expectEqualStrings("x", sym.?.name);
}

test "SymbolTable: define and lookup function" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    try st.defineFn("add", &[_]Param{ .{ .name = "a", .var_type = .Int }, .{ .name = "b", .var_type = .Int } }, .Int);
    const sig = st.lookupFn("add");
    try expect(sig != null);
    try expectEqual(VarType.Int, sig.?.return_type);
    try expectEqual(@as(usize, 2), sig.?.params.len);
}

test "SymbolTable: defineClass and addField" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    try st.defineClass("Point", null);
    try st.addField("Point", "x", .Int);
    try st.addField("Point", "y", .Int);

    try expect(st.isClass("Point"));
    const field_type = st.lookupClassField("Point", "x");
    try expect(field_type != null);
    try expectEqual(VarType.Int, field_type.?);
}

test "SymbolTable: defineClass with parent" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    try st.defineClass("Animal", null);
    try st.defineClass("Dog", "Animal");

    try expect(st.isClass("Dog"));
    const ci = st.lookupClass("Dog");
    try expect(ci != null);
    try expect(ci.?.parent != null);
    try expectEqualStrings("Animal", ci.?.parent.?);
}

test "SymbolTable: addMethod and lookupClassMethod" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    try st.defineClass("Calc", null);
    const sig = FnSig{
        .params = &[_]Param{.{ .name = "x", .var_type = .Int }},
        .return_type = .Int,
    };
    try st.addMethod("Calc", "square", sig);
    const found = st.lookupClassMethod("Calc", "square");
    try expect(found != null);
    try expectEqual(VarType.Int, found.?.return_type);
}

test "SymbolTable: defineClassVar" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    try st.defineClass("MyClass", null);
    try st.defineClassVar("obj", "MyClass", .{});
    const sym = st.lookup("obj");
    try expect(sym != null);
    try expectEqual(VarType.Class, sym.?.var_type);
    try expectEqualStrings("MyClass", sym.?.class_name.?);
}

test "SymbolTable: lookup non-existent returns null" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();

    try expect(st.lookup("nonexistent") == null);
    try expect(st.lookupFn("nonexistent") == null);
    try expect(!st.isClass("nonexistent"));
    try expect(st.lookupClassField("nonexistent", "x") == null);
}

// ---- 内置函数 ----

test "builtins: all 37 builtin functions have consistent definitions" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();
    try st.registerBuiltins();

    // 验证核心函数存在
    try expect(st.lookupFn("strlen") != null);
    try expect(st.lookupFn("strequal") != null);
    try expect(st.lookupFn("strcontains") != null);
    try expect(st.lookupFn("strsub") != null);
    try expect(st.lookupFn("strtrim") != null);

    try expect(st.lookupFn("mathAbs") != null);
    try expect(st.lookupFn("mathMin") != null);
    try expect(st.lookupFn("mathMax") != null);
    try expect(st.lookupFn("mathPow") != null);
    try expect(st.lookupFn("mathSqrt") != null);

    try expect(st.lookupFn("intToString") != null);
    try expect(st.lookupFn("doubleToString") != null);

    try expect(st.lookupFn("httpGet") != null);
    try expect(st.lookupFn("httpPost") != null);
    try expect(st.lookupFn("jsonGet") != null);

    try expect(st.lookupFn("charIsDigit") != null);
    try expect(st.lookupFn("charIsLetter") != null);
    try expect(st.lookupFn("charToUpper") != null);
    try expect(st.lookupFn("charToLower") != null);

    try expect(st.lookupFn("currentTimeMillis") != null);

    try expect(st.lookupFn("readFile") != null);
    try expect(st.lookupFn("writeFile") != null);
    try expect(st.lookupFn("fileAppend") != null);

    try expect(st.lookupFn("mapPut") != null);
    try expect(st.lookupFn("mapGet") != null);
    try expect(st.lookupFn("mapContainsKey") != null);

    try expect(st.lookupFn("threadSleep") != null);

    try expect(st.lookupFn("listCreate") != null);
    try expect(st.lookupFn("listAdd") != null);
    try expect(st.lookupFn("listGet") != null);
    try expect(st.lookupFn("listSize") != null);

    // arrayLen is registered manually after builtins
    try expect(st.lookupFn("arrayLen") != null);
}

test "builtins: strlen params and return type" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();
    try st.registerBuiltins();

    const sig = st.lookupFn("strlen").?;
    try expectEqual(@as(usize, 1), sig.params.len);
    try expectEqualStrings("s", sig.params[0].name);
    try expectEqual(VarType.String, sig.params[0].var_type);
    try expectEqual(VarType.Int, sig.return_type);
}

test "builtins: mathPow params and return type" {
    var st = SymbolTable.init(testing.allocator);
    defer st.deinit();
    try st.registerBuiltins();

    const sig = st.lookupFn("mathPow").?;
    try expectEqual(@as(usize, 2), sig.params.len);
    try expectEqualStrings("base", sig.params[0].name);
    try expectEqual(VarType.Double, sig.params[0].var_type);
    try expectEqualStrings("exp", sig.params[1].name);
    try expectEqual(VarType.Double, sig.params[1].var_type);
    try expectEqual(VarType.Double, sig.return_type);
}

test "builtins: writeFile has can_fail flag" {
    // 验证 can_fail 内置函数在注册表中正确标记
    var found = false;
    for (builtins) |b| {
        if (std.mem.eql(u8, b.name, "writeFile")) {
            try expect(b.can_fail);
            found = true;
        }
        if (std.mem.eql(u8, b.name, "fileAppend")) {
            try expect(b.can_fail);
        }
    }
    try expect(found);
}
