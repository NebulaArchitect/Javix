// ============================================================
// 文件名: config.zig
// ============================================================

const std = @import("std");

// ------------------------------------------------------------
// 内存模型（后续扩展，MVP 默认使用 Auto）
// ------------------------------------------------------------
pub const MemoryModel = enum {
    manual,     // 裸金属手动内存
    refcount,   // 引用计数（默认）
    simple_gc,  // 简易 GC
    auto,       // 自动选择（当前映射到 refcount）
};

// ------------------------------------------------------------
// 编译目标
// ------------------------------------------------------------
pub const TargetOutput = enum {
    exe,    // Windows/Linux 原生可执行文件
    wasm,   // WebAssembly
};

// ------------------------------------------------------------
// Javix 全局配置
// ------------------------------------------------------------
pub const Config = struct {
    memory_model: MemoryModel = .auto,
    output: TargetOutput = .exe,
    optimize: bool = false,
    verbose: bool = false,
    show_tokens: bool = false,
    show_ast: bool = false,

    pub fn fromArgs(allocator: std.mem.Allocator, args: [][]const u8) !Config {
        _ = allocator;
        var cfg = Config{};
        for (args) |arg| {
            if (std.mem.eql(u8, arg, "--verbose")) {
                cfg.verbose = true;
            } else if (std.mem.eql(u8, arg, "--show-tokens")) {
                cfg.show_tokens = true;
            } else if (std.mem.eql(u8, arg, "--show-ast")) {
                cfg.show_ast = true;
            }
        }
        return cfg;
    }
};
