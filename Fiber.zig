const std = @import("std");
const builtin = @import("builtin");

const Fiber = @import("Fiber.zig");

/// There is no reason to do this other than
/// a lack of arch support - please don't use this
const use_ucontext = std.meta.globalOption("oatz_use_ucontext", bool) orelse false;

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

// NOTE: NEVER MODIFY THIS PLEASE USER
pub threadlocal var current: ?*Fiber = null;

pub fn switchTo(fiber: *Fiber) Error!void {
    const s = current;
    current = fiber;

    try impl.switchTo(fiber.allocator, &fiber.context);

    current = s;
}

pub fn yield(fiber: *Fiber) void {
    impl.yield(fiber.allocator, &fiber.context);
}
