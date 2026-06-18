const std = @import("std");
const SymbolTable = @import("ast.zig").SymbolTable;

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
};