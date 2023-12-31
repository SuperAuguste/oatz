const std = @import("std");
const Fiber = @import("../Fiber.zig");

comptime {
    asm (
        \\.global _oatz_arm64_switchTo
        \\_oatz_arm64_switchTo:
        \\    stp     d15, d14, [sp, #-22*8]!
        \\    stp     d13, d12, [sp, #2*8]
        \\    stp     d11, d10, [sp, #4*8]
        \\    stp     d9,  d8,  [sp, #6*8]
        \\    stp     x30, x29, [sp, #8*8]
        \\    stp     x28, x27, [sp, #10*8]
        \\    stp     x26, x25, [sp, #12*8]
        \\    stp     x24, x23, [sp, #14*8]
        \\    stp     x22, x21, [sp, #16*8]
        \\    stp     x20, x19, [sp, #18*8]
        \\    stp     x0,  x1,  [sp, #20*8]
        \\    
        \\    mov     x19, sp            
        \\    str     x19, [x0, #0]
        \\    mov     x19, #1           
        \\    str     x19, [x0, #8]
        \\    
        \\    mov     x19, #0              
        \\    str     x19, [x1, #8]
        \\    ldr     x19, [x1, #0]      
        \\    mov     sp, x19
        \\    
        \\    ldp     x0,  x1,  [sp, #20*8] 
        \\    ldp     x20, x19, [sp, #18*8]
        \\    ldp     x22, x21, [sp, #16*8]
        \\    ldp     x24, x23, [sp, #14*8]
        \\    ldp     x26, x25, [sp, #12*8]
        \\    ldp     x28, x27, [sp, #10*8]
        \\    ldp     x30, x29, [sp, #8*8]  
        \\    ldp     d9,  d8,  [sp, #6*8]
        \\    ldp     d11, d10, [sp, #4*8]
        \\    ldp     d13, d12, [sp, #2*8]
        \\    ldp     d15, d14, [sp], #22*8
        \\    
        \\    mov     x16, x30 
        \\    mov     x30, #0  
        \\    br      x16
    );
}

pub const Error = error{
    Unexpected,
    OutOfMemory,
    NotResumable,
};

pub const Context = struct {
    stack: []const usize,
    caller_ctx: InternalContext,
    fiber_ctx: InternalContext,

    func_and_args: *anyopaque,
};

pub const InternalContext = extern struct {
    stack_top: *anyopaque,
    resumable: c_long,
    registers: [20]usize = undefined,
};

pub extern fn oatz_arm64_switchTo(current_context: *InternalContext, new_context: *InternalContext) void;

pub fn init(
    comptime Fn: type,
    fiber: *Fiber,
    stack_size: usize,
    func: anytype,
    args: anytype,
) Error!void {
    const allocator = fiber.allocator;

    const Args = @TypeOf(args);
    const WrappedCaller = struct {
        func: *const Fn,
        args: Args,

        fn wrappedFunc(fib: *Fiber) void {
            const wc = @ptrCast(*@This(), @alignCast(@alignOf(@This()), fib.context.func_and_args));
            const wcd = wc.*;

            fib.allocator.destroy(wc);
            @call(.auto, wcd.func, wcd.args);

            fib.yield();
        }
    };

    var wrapped_caller = try allocator.create(WrappedCaller);
    wrapped_caller.* = .{
        .func = func,
        .args = args,
    };

    var stack = try allocator.allocWithOptions(usize, @divTrunc(stack_size, @sizeOf(usize)), 16, null);

    var caller_ctx: InternalContext = undefined;
    var fiber_ctx = InternalContext{
        .stack_top = stack.ptr + stack.len - 22,
        .resumable = 1,
    };

    stack[stack.len - 2] = @ptrToInt(fiber);
    stack[stack.len - 14] = @ptrToInt(&WrappedCaller.wrappedFunc);

    fiber.context = .{
        .stack = stack,
        .caller_ctx = caller_ctx,
        .fiber_ctx = fiber_ctx,

        .func_and_args = wrapped_caller,
    };
}

pub fn deinit(allocator: std.mem.Allocator, ctx: *Context) void {
    allocator.free(ctx.stack);
}

pub fn switchTo(allocator: std.mem.Allocator, ctx: *Context) Error!void {
    _ = allocator;
    if (ctx.fiber_ctx.resumable == 0)
        return error.NotResumable;
    oatz_arm64_switchTo(&ctx.caller_ctx, &ctx.fiber_ctx);
}

pub fn yield(allocator: std.mem.Allocator, ctx: *Context) void {
    _ = allocator;
    if (ctx.caller_ctx.resumable == 0)
        @panic("Caller not resumable!");
    oatz_arm64_switchTo(&ctx.fiber_ctx, &ctx.caller_ctx);
}
