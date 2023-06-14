const std = @import("std");
const Fiber = @import("Fiber.zig");

fn hello(value: *usize, other_fiber: *Fiber) void {
    std.testing.expectEqual(value.*, @as(usize, 5)) catch @panic("Fail");
    other_fiber.switchTo() catch @panic("switchTo failed!");
    std.testing.expectEqual(value.*, @as(usize, 10)) catch @panic("Fail");
    Fiber.current.?.yield();
    std.testing.expectEqual(value.*, @as(usize, 17)) catch @panic("Fail");
    other_fiber.switchTo() catch @panic("switchTo failed!");
    other_fiber.switchTo() catch @panic("switchTo failed!");
    other_fiber.switchTo() catch @panic("switchTo failed!");
}

fn hello2(value: *usize) void {
    value.* += 5;
    Fiber.current.?.yield();
    Fiber.current.?.yield();
    Fiber.current.?.yield();
}

test {
    const allocator = std.testing.allocator;

    var val: usize = 0;

    var fiber_2 = try Fiber.create(allocator, 16_384, hello2, .{&val});
    defer fiber_2.destroy();

    var fiber = try Fiber.create(allocator, 16_384, hello, .{ &val, fiber_2 });
    defer fiber.destroy();

    val = 5;
    try fiber.switchTo();
    val += 7;
    try fiber.switchTo();
}
