const std = @import("std");
const builtin = @import("builtin");

const Fiber = @import("Fiber.zig");

/// There is no reason to do this other than
/// a lack of arch support - please don't use this
const use_ucontext = std.meta.globalOption("oatz_use_ucontext", bool) orelse false;
const not_supported_message = "Not supported; please open an issue or see oatz_use_context";

const impl = if (use_ucontext) @import("impls/ucontext.zig") else switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be, .aarch64_32 => @import("impls/aarch64.zig"),
    else => @compileError("Not supported; please open an issue or see oatz_use_context"),
};

pub const Error = impl.Error;

allocator: std.mem.Allocator,
context: impl.Context,

fn resolveFnType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .Fn => T,
        .Pointer => |ptr| {
            if (ptr.size != .One or @typeInfo(ptr.child) != .Fn)
                return resolveFnType(void);

            return resolveFnType(ptr.child);
        },
        else => @compileError("Fiber `func` must be a function or single-pointer to a function!"),
    };
}

pub fn create(
    allocator: std.mem.Allocator,
    stack_size: usize,
    func: anytype,
    args: anytype,
) Error!*Fiber {
    const T = @TypeOf(func);
    if (@typeInfo(T) == .Fn) return create(allocator, stack_size, &func, args);

    const Fn = resolveFnType(T);
    const funcInfo = @typeInfo(Fn).Fn;

    if (funcInfo.return_type == null or
        comptime for (funcInfo.params) |param|
        (if (param.type == null)
            break true)
    else
        false) @compileError("Fiber `func` cannot be generic!");

    if (funcInfo.return_type.? != void) @compileError("Fibers must not return anything (" ++ @typeName(funcInfo.return_type.?) ++ " != void)");

    var fiber = try allocator.create(Fiber);
    fiber.allocator = allocator;
    try impl.init(Fn, fiber, stack_size, func, args);

    return fiber;
}

pub fn destroy(fiber: *Fiber) void {
    impl.deinit(fiber.allocator, &fiber.context);
    fiber.allocator.destroy(fiber);
}

pub threadlocal var current_fiber: ?*Fiber = null;

pub fn swap(fiber: *Fiber) Error!void {
    const s = current_fiber;
    current_fiber = fiber;

    try impl.swap(fiber.allocator, &fiber.context);

    current_fiber = s;
}

pub fn swapBack(fiber: *Fiber) Error!void {
    try impl.swapBack(fiber.allocator, &fiber.context);
}

fn hello(num: usize, other_fiber: *Fiber) void {
    std.debug.print("\n\nHi from hello 1: {*}!\n\n", .{current_fiber});
    other_fiber.swap() catch @panic("bruh1");
    std.debug.print("\n\nHi from hello 1: {*}!\n\n", .{current_fiber});
    current_fiber.?.swapBack() catch @panic("bruh2");
    std.debug.print("\n\nHi from hello 2: {d}!\n\n", .{num});
}

fn hello2(num: usize) void {
    std.debug.print("\n\nHi from hello 222: {*}!\n\n", .{current_fiber});
    std.debug.print("\n\nHi from fiber 2: {d}!\n\n", .{num});
}

test {
    const allocator = std.testing.allocator;

    var fiber2 = try Fiber.create(allocator, 16_384, hello2, .{69});
    defer fiber2.destroy();

    var fiber = try Fiber.create(allocator, 16_384, hello, .{ 123, fiber2 });
    defer fiber.destroy();

    std.debug.print("\n\nHi from og stack 1 {*}\n\n", .{fiber});
    try fiber.swap();
    std.debug.print("\n\nHi from og stack 2 {any}\n\n", .{current_fiber});
    try fiber.swap();
    std.debug.print("\n\nHi from og stack 3 {any}\n\n", .{current_fiber});
}
