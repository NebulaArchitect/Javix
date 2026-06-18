// ============================================================
// 文件名: src/runtime/javax_runtime.zig
// ============================================================

const std = @import("std");


/// strlen(s) → 字符串长度
pub fn strlen(s: []const u8) i64 {
    return @intCast(s.len);
}

/// strsub(alloc, s, start, len) → 子串 [start, start+len)
/// 对标 String.substring()
pub fn strsub(allocator: std.mem.Allocator, s: []const u8, start: i64, len: i64) ![]const u8 {
    const ustart: usize = @intCast(@max(0, start));
    const available: i64 = @as(i64, @intCast(s.len)) - start;
    const actual_len: usize = @intCast(@max(0, @min(len, available)));
    const end = @min(ustart + actual_len, s.len);
    return try allocator.dupe(u8, s[ustart..end]);
}

/// strequal(a, b) → 字符串是否相等
/// 对标 String.equals()
pub fn strequal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// strtrim(alloc, s) → 去除首尾空白字符
/// 对标 String.trim()
pub fn strtrim(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\r\n");
    return try allocator.dupe(u8, trimmed);
}

/// strcontains(s, needle) → s 是否包含 needle
/// 对标 String.contains()
pub fn strcontains(s: []const u8, needle: []const u8) bool {
    return std.mem.containsAtLeast(u8, s, 1, needle);
}

// ============================================================
// Math 操作 —— 对标 java.lang.Math
// ============================================================

pub fn mathAbs(x: i64) i64 {
    return if (x < 0) -x else x;
}

pub fn mathAbsDouble(x: f64) f64 {
    return if (x < 0) -x else x;
}

pub fn mathMin(a: i64, b: i64) i64 {
    return @min(a, b);
}

pub fn mathMax(a: i64, b: i64) i64 {
    return @max(a, b);
}

pub fn mathMinDouble(a: f64, b: f64) f64 {
    return @min(a, b);
}

pub fn mathMaxDouble(a: f64, b: f64) f64 {
    return @max(a, b);
}

pub fn mathPow(base: f64, exp: f64) f64 {
    return std.math.pow(f64, base, exp);
}

pub fn mathSqrt(x: f64) f64 {
    return std.math.sqrt(x);
}

// ============================================================
// 类型转换 —— 对标 String.valueOf / Integer.parseInt
// ============================================================

/// intToString(alloc, x) → 整数转字符串
pub fn intToString(allocator: std.mem.Allocator, x: i64) ![]const u8 {
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{x});
    return try allocator.dupe(u8, s);
}

/// doubleToString(alloc, x) → 浮点数转字符串
pub fn doubleToString(allocator: std.mem.Allocator, x: f64) ![]const u8 {
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{x});
    return try allocator.dupe(u8, s);
}

// ============================================================
// 数组操作
// ============================================================

/// arrayLen(arr) → 数组长度
pub fn arrayLen(arr: anytype) i64 {
    return @intCast(arr.len);
}

// ============================================================
// HTTP 客户端
// ============================================================

/// httpGet(alloc, url) → HTTP GET 请求，返回响应体
pub fn httpGet(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;
    var req = try client.open(.GET, uri, .{ .server_header_buffer = &buf });
    defer req.deinit();

    try req.send();
    try req.wait();

    const body = try req.reader().readAllAlloc(allocator, 1024 * 1024);
    return body;
}

/// httpPost(alloc, url, body) → HTTP POST 请求，返回响应体
pub fn httpPost(allocator: std.mem.Allocator, url: []const u8, body: []const u8) ![]const u8 {
    const uri = try std.Uri.parse(url);
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var buf: [4096]u8 = undefined;
    var req = try client.open(.POST, uri, .{ .server_header_buffer = &buf });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    var w = req.writer();
    try w.writeAll(body);
    try req.finish();
    try req.wait();

    const resp = try req.reader().readAllAlloc(allocator, 1024 * 1024);
    return resp;
}

// ============================================================
// JSON 解析
// ============================================================

/// jsonGet(json_str, key) → 从简单 JSON 对象中获取字符串值
/// 支持格式: {"key": "value", "key2": 123}
pub fn jsonGet(allocator: std.mem.Allocator, json_str: []const u8, key: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const val = parsed.value.object.get(key) orelse return try allocator.dupe(u8, "");
    
    switch (val) {
        .string => |s| {
            return try allocator.dupe(u8, s);
        },
        .integer => |i| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
            return try allocator.dupe(u8, s);
        },
        .float => |f| {
            var buf: [64]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{f});
            return try allocator.dupe(u8, s);
        },
        .bool => |b| {
            return try allocator.dupe(u8, if (b) "true" else "false");
        },
        .null => return try allocator.dupe(u8, "null"),
        else => return try allocator.dupe(u8, ""),
    }
}

// ============================================================
// Character 操作 —— 对标 java.lang.Character
// ============================================================

pub fn charIsDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn charIsLetter(c: u8) bool {
    return (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z');
}

pub fn charToUpper(c: u8) u8 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

pub fn charToLower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

// ============================================================
// 日期时间 —— 对标 java.lang.System.currentTimeMillis()
// ============================================================

pub fn currentTimeMillis() i64 {
    // Zig 0.16: 使用 std.time.microTimestamp（如果存在）或 milliTimestamp
    if (@hasDecl(std.time, "milliTimestamp")) {
        return std.time.milliTimestamp();
    }
    if (@hasDecl(std.time, "microTimestamp")) {
        return @divTrunc(std.time.microTimestamp(), 1000);
    }
    return 0;
}

// ============================================================
// 集合框架 —— HashMap<String,String> 全局单例
// ============================================================

var global_map: ?std.StringHashMap([]const u8) = null;
var global_map_arena: ?std.heap.ArenaAllocator = null;

fn ensureMap() void {
    if (global_map == null) {
        global_map_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        global_map = std.StringHashMap([]const u8).init(global_map_arena.?.allocator());
    }
}

pub fn mapPut(allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    _ = allocator;
    ensureMap();
    const key_copy = try global_map_arena.?.allocator().dupe(u8, key);
    const val_copy = try global_map_arena.?.allocator().dupe(u8, value);
    try global_map.?.put(key_copy, val_copy);
}

pub fn mapGet(allocator: std.mem.Allocator, key: []const u8) ![]const u8 {
    _ = allocator;
    ensureMap();
    return global_map.?.get(key) orelse "";
}

pub fn mapContainsKey(key: []const u8) bool {

    ensureMap();
    return global_map.?.contains(key);
}

// ============================================================
// 文件 IO —— 对标 java.io 基础操作（kernel32 直调，绕过 Zig std.Io）
// ============================================================

const HANDLE = isize;
const INVALID_HANDLE: HANDLE = -1;
extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: HANDLE) callconv(.winapi) HANDLE;
extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) u32;
extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) u32;
extern "kernel32" fn SetFilePointerEx(hFile: HANDLE, liDistanceToMove: i64, lpNewFilePointer: ?*i64, dwMoveMethod: u32) callconv(.winapi) u32;

const GENERIC_READ = 0x80000000;
const GENERIC_WRITE = 0x40000000;
const FILE_SHARE_READ = 1;
const FILE_SHARE_WRITE = 2;
const OPEN_EXISTING = 3;
const CREATE_ALWAYS = 2;
const OPEN_ALWAYS = 4;
const FILE_ATTRIBUTE_NORMAL = 128;
const FILE_END: u32 = 2;

pub fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const h = CreateFileA(path_z, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE) return error.FileNotFound;
    defer _ = CloseHandle(h);

    var size: i64 = 0;
    _ = GetFileSizeEx(h, &size);
    const buf = try allocator.alloc(u8, @intCast(size));
    var read: u32 = 0;
    _ = ReadFile(h, buf.ptr, @intCast(size), &read, null);
    return buf[0..@intCast(read)];
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const h = CreateFileA(path_z, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE) return error.FileWriteError;
    defer _ = CloseHandle(h);

    var written: u32 = 0;
    _ = WriteFile(h, data.ptr, @intCast(data.len), &written, null);
}

pub fn fileAppend(path: []const u8, data: []const u8) !void {
    const path_z = try std.heap.page_allocator.dupeZ(u8, path);
    defer std.heap.page_allocator.free(path_z);
    const h = CreateFileA(path_z, GENERIC_WRITE, 0, null, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (h == INVALID_HANDLE) return error.FileWriteError;
    defer _ = CloseHandle(h);

    _ = SetFilePointerEx(h, 0, null, FILE_END);
    var written: u32 = 0;
    _ = WriteFile(h, data.ptr, @intCast(data.len), &written, null);
}

// ============================================================
// 多线程 —— 对标 java.lang.Thread
// ============================================================

/// threadSleep(ms) → 当前线程睡眠 ms 毫秒
extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
pub fn threadSleep(ms: i64) void {
    Sleep(@intCast(@max(0, ms)));
}

// ============================================================
// ArrayList (String列表) —— 对标 java.util.ArrayList
// ============================================================

var lists: ?std.AutoHashMap(i64, std.ArrayList([]const u8)) = null;
var list_counter: i64 = 0;
var list_arena: ?std.heap.ArenaAllocator = null;

fn ensureLists() void {
    if (lists == null) {
        list_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        lists = std.AutoHashMap(i64, std.ArrayList([]const u8)).init(list_arena.?.allocator());
    }
}

pub fn listCreate(allocator: std.mem.Allocator) !i64 {
    _ = allocator;
    ensureLists();
    const id = list_counter;
    list_counter += 1;
    const al: std.ArrayList([]const u8) = .{ .items = &.{}, .capacity = 0 };
    try lists.?.put(id, al);
    return id;
}

pub fn listAdd(allocator: std.mem.Allocator, handle: i64, item: []const u8) !void {
    _ = allocator;
    ensureLists();
    if (lists.?.getPtr(handle)) |al| {
        const copy = try list_arena.?.allocator().dupe(u8, item);
        try al.append(list_arena.?.allocator(), copy);
    }
}

pub fn listGet(allocator: std.mem.Allocator, handle: i64, index: i64) ![]const u8 {
    _ = allocator;
    ensureLists();
    if (lists.?.get(handle)) |al| {
        const idx: usize = @intCast(@max(0, index));
        if (idx < al.items.len) return al.items[idx];
    }
    return "";
}

pub fn listSize(handle: i64) i64 {
    ensureLists();
    if (lists.?.get(handle)) |al| return @intCast(al.items.len);
    return 0;
}
