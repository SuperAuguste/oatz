const std = @import("std");
const builtin = @import("builtin");

const Fiber = @import("Fiber.zig");

/// There is no reason to do this other than
/// a lack of arch support - please don't use this
const use_ucontext = std.meta.globalOption("oatz_use_ucontext", bool) orelse true;
const not_supported_message = "Not supported; please open an issue or see oatz_use_context";

const platform = if (use_ucontext) struct {
    const c = @cImport({
        @cDefine("_XOPEN_SOURCE", "");
        @cInclude("ucontext.h");
    });

    const ucontext_t = c.ucontext_t;
    extern "c" fn getcontext(ucp: *ucontext_t) callconv(.C) c_int;
    extern "c" fn makecontext(ucp: *ucontext_t, func: *const anyopaque, argc: c_int, ...) callconv(.C) void;
    extern "c" fn swapcontext(oucp: *ucontext_t, ucp: *ucontext_t) callconv(.C) c_int;
} else @compileError(not_supported_message);

pub const Error = if (use_ucontext) error{
    Unexpected,
    OutOfMemory,
} else @compileError(not_supported_message);
pub const Context = if (use_ucontext) struct {
    oucp: *platform.ucontext_t,
    ucp: *platform.ucontext_t,

    args: *anyopaque,
    ret: *anyopaque,
    free: *const fn (allocator: std.mem.Allocator, *anyopaque, *anyopaque) void,

    stack: []const u8,
} else @compileError(not_supported_message);

allocator: std.mem.Allocator,
context: Context,

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

pub fn init(
    allocator: std.mem.Allocator,
    stack_size: usize,
    func: anytype,
    args: anytype,
) Error!Fiber {
    const T = @TypeOf(func);
    if (@typeInfo(T) == .Fn) return init(allocator, stack_size, &func, args);

    const Fn = resolveFnType(T);
    const funcInfo = @typeInfo(Fn).Fn;

    if (funcInfo.return_type == null or
        comptime for (funcInfo.params) |param|
        (if (param.type == null)
            break true)
    else
        false) @compileError("Fiber `func` cannot be generic!");

    if (use_ucontext) {
        var ucp = try allocator.create(platform.ucontext_t);
        var oucp = try allocator.create(platform.ucontext_t);

        var gc_err = std.c.getErrno(platform.getcontext(ucp));
        if (gc_err != .SUCCESS) {
            return std.os.unexpectedErrno(gc_err);
        }

        var stack = try allocator.alloc(u8, stack_size);

        ucp.uc_stack.ss_sp = stack.ptr;
        ucp.uc_stack.ss_size = stack.len;
        ucp.uc_stack.ss_flags = 0;
        ucp.uc_link = oucp;

        const Args = std.meta.ArgsTuple(Fn);
        const Ret = funcInfo.return_type.?;

        var allocated_args = try allocator.create(Args);
        allocated_args.* = args;

        var allocated_ret = try allocator.create(Ret);

        // We have to use a variety of awful hacks here because libc sux
        // (main issue is that it only supports 32-bit values)

        // TODO: Support 32-bit systems
        const run = struct {
            fn r(func_0: u32, func_1: u32, args_0: u32, args_1: u32, ret_0: u32, ret_1: u32) callconv(.C) void {
                var func_01 = @ptrCast(*const Fn, @alignCast(@alignOf(Fn), @intToPtr(*const anyopaque, @bitCast(usize, [2]u32{ func_0, func_1 }))));
                var args_01 = @intToPtr(*const Args, @bitCast(usize, [2]u32{ args_0, args_1 }));

                if (@sizeOf(Ret) != 0) {
                    var ret_01 = @intToPtr(*Ret, @bitCast(usize, [2]u32{ ret_0, ret_1 }));
                    ret_01.* = @call(.auto, func_01, args_01.*);
                } else {
                    @call(.auto, func_01, args_01.*);
                }
            }
        }.r;

        const us = @typeInfo(usize).Int.bits;
        var func_01 = @bitCast([us / 32]u32, @ptrToInt(@ptrCast(*const anyopaque, func)));
        var args_01 = @bitCast([us / 32]u32, @ptrToInt(allocated_args));
        var ret_01 = @bitCast([us / 32]u32, @ptrToInt(allocated_ret));

        platform.makecontext(ucp, &run, 6, func_01[0], func_01[1], args_01[0], args_01[1], ret_01[0], ret_01[1]);

        return Fiber{
            .allocator = allocator,
            .context = Context{
                .oucp = oucp,
                .ucp = ucp,
                .stack = stack,
                .args = allocated_args,
                .ret = allocated_ret,
                .free = &struct {
                    fn free(all: std.mem.Allocator, op: *anyopaque, rt: *anyopaque) void {
                        all.destroy(@ptrCast(*Args, @alignCast(@alignOf(Args), op)));
                        if (@sizeOf(Ret) != 0)
                            all.destroy(@ptrCast(*Ret, @alignCast(@alignOf(Ret), rt)));
                    }
                }.free,
            },
        };
    }

    @compileError(not_supported_message);
}

pub fn deinit(fiber: Fiber) void {
    if (use_ucontext) {
        fiber.allocator.destroy(fiber.context.oucp);
        fiber.allocator.destroy(fiber.context.ucp);
        fiber.context.free(fiber.allocator, fiber.context.args, fiber.context.ret);
        fiber.allocator.free(fiber.context.stack);
    }
}

pub fn swap(fiber: Fiber) Error!void {
    if (use_ucontext) {
        var sc_err = std.c.getErrno(platform.swapcontext(fiber.context.oucp, fiber.context.ucp));
        if (sc_err != .SUCCESS) {
            return std.os.unexpectedErrno(sc_err);
        }

        return;
    }

    @compileError(not_supported_message);
}

fn hello(msg: []const u8, other_fiber: Fiber) !void {
    try other_fiber.swap();
    std.debug.print("\n\nHi from fiber 1: {s}!\n\n", .{msg});
}

fn hello2(msg: []const u8) void {
    std.debug.print("\n\nHi from fiber 2: {s}!\n\n", .{msg});
}

test {
    const allocator = std.testing.allocator;

    var fiber2 = try Fiber.init(allocator, 16_384, &hello2, .{"Zig2!"});
    defer fiber2.deinit();

    var fiber = try Fiber.init(allocator, 16_384, &hello, .{ "Zig!", fiber2 });
    defer fiber.deinit();

    std.debug.print("\n\nHi from og stack 1\n\n", .{});
    try fiber.swap();
    std.debug.print("\n\nHi from og stack 2\n\n", .{});
}
