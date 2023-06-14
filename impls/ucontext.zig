const std = @import("std");
const Fiber = @import("../Fiber.zig");

const c = @cImport({
    @cDefine("_XOPEN_SOURCE", "");
    @cInclude("ucontext.h");
});

const ucontext_t = c.ucontext_t;
extern "c" fn getcontext(ucp: *ucontext_t) callconv(.C) c_int;
extern "c" fn makecontext(ucp: *ucontext_t, func: *const anyopaque, argc: c_int, ...) callconv(.C) void;
extern "c" fn swapcontext(oucp: *ucontext_t, ucp: *ucontext_t) callconv(.C) c_int;

pub const Error = error{
    Unexpected,
    OutOfMemory,
};

pub const Context = struct {
    oucp: *ucontext_t,
    ucp: *ucontext_t,

    args: *anyopaque,
    free: *const fn (allocator: std.mem.Allocator, *anyopaque) void,

    stack: []const u8,
};

pub fn init(
    comptime Fn: type,
    fiber: *Fiber,
    stack_size: usize,
    func: anytype,
    args: anytype,
) Error!void {
    const allocator = fiber.allocator;

    var ucp = try allocator.create(ucontext_t);
    var oucp = try allocator.create(ucontext_t);

    var gc_err = std.c.getErrno(getcontext(ucp));
    if (gc_err != .SUCCESS) {
        return std.os.unexpectedErrno(gc_err);
    }

    var stack = try allocator.alloc(u8, stack_size);

    ucp.uc_stack.ss_sp = stack.ptr;
    ucp.uc_stack.ss_size = stack.len;
    ucp.uc_stack.ss_flags = 0;
    ucp.uc_link = oucp;

    const Args = std.meta.ArgsTuple(Fn);

    var allocated_args = try allocator.create(Args);
    allocated_args.* = args;

    // We have to use a variety of awful hacks here because libc sux
    // (main issue is that it only supports 32-bit values)

    // TODO: Support 32-bit systems
    const run = struct {
        fn r(func_0: u32, func_1: u32, args_0: u32, args_1: u32) callconv(.C) void {
            var func_01 = @ptrCast(*const Fn, @alignCast(@alignOf(Fn), @intToPtr(*const anyopaque, @bitCast(usize, [2]u32{ func_0, func_1 }))));
            var args_01 = @intToPtr(*const Args, @bitCast(usize, [2]u32{ args_0, args_1 }));

            @call(.auto, func_01, args_01.*);
        }
    }.r;

    const us = @typeInfo(usize).Int.bits;
    var func_01 = @bitCast([us / 32]u32, @ptrToInt(@ptrCast(*const anyopaque, func)));
    var args_01 = @bitCast([us / 32]u32, @ptrToInt(allocated_args));

    makecontext(ucp, &run, 4, func_01[0], func_01[1], args_01[0], args_01[1]);

    fiber.context = .{
        .oucp = oucp,
        .ucp = ucp,
        .stack = stack,
        .args = allocated_args,
        .free = &struct {
            fn free(all: std.mem.Allocator, op: *anyopaque) void {
                all.destroy(@ptrCast(*Args, @alignCast(@alignOf(Args), op)));
            }
        }.free,
    };
}

pub fn deinit(allocator: std.mem.Allocator, ctx: *Context) void {
    allocator.destroy(ctx.oucp);
    allocator.destroy(ctx.ucp);
    ctx.free(allocator, ctx.args);
    allocator.free(ctx.stack);
}

pub fn switchTo(allocator: std.mem.Allocator, ctx: *Context) Error!void {
    _ = allocator;
    var sc_err = std.c.getErrno(swapcontext(ctx.oucp, ctx.ucp));
    if (sc_err != .SUCCESS) {
        return std.os.unexpectedErrno(sc_err);
    }
}

pub fn yield(allocator: std.mem.Allocator, ctx: *Context) Error!void {
    _ = allocator;
    var sc_err = std.c.getErrno(swapcontext(ctx.ucp, ctx.oucp));
    if (sc_err != .SUCCESS) {
        return std.os.unexpectedErrno(sc_err);
    }
}
