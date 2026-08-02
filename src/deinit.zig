const std = @import("std");

pub const DeinitFunction = *const fn (*anyopaque, *const std.mem.Allocator) callconv(.c) void;

pub fn getDeinitFunction(comptime T: type) DeinitFunction {
    return struct {
        fn deinitFunction(ptr: *anyopaque, allocator: *const std.mem.Allocator) callconv(.c) void {
            const instance: *T = @ptrCast(@alignCast(ptr));
            deinitIfPresent(T, instance, allocator.*);
            allocator.destroy(instance);
        }
    }.deinitFunction;
}

pub fn deinitIfPresent(comptime T: type, instance: *T, allocator: std.mem.Allocator) void {
    if (!std.meta.hasFn(T, "deinit")) return;
    const params = @typeInfo(@TypeOf(T.deinit)).@"fn".params;
    switch (params.len) {
        1 => instance.deinit(),
        2 => instance.deinit(allocator),
        else => @compileError(@typeName(T) ++ ".deinit has an unsupported signature"),
    }
}

test "getDeinitFunction calls a two-argument deinit and frees the instance" {
    const State = struct {
        var count: usize = 0;
    };
    const Type = struct {
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            State.count += 1;
        }
    };

    const allocator = std.testing.allocator;
    const instance = try allocator.create(Type);
    instance.* = .{};

    const deinit_function = getDeinitFunction(Type);
    deinit_function(instance, &allocator);

    try std.testing.expectEqual(1, State.count);
}

test "getDeinitFunction calls a one-argument deinit and frees the instance" {
    const State = struct {
        var count: usize = 0;
    };
    const Type = struct {
        pub fn deinit(_: *@This()) void {
            State.count += 1;
        }
    };

    const allocator = std.testing.allocator;
    const instance = try allocator.create(Type);
    instance.* = .{};

    const deinit_function = getDeinitFunction(Type);
    deinit_function(instance, &allocator);

    try std.testing.expectEqual(1, State.count);
}

test "getDeinitFunction just frees the instance when deinit is absent" {
    const Type = struct {};

    const allocator = std.testing.allocator;
    const instance = try allocator.create(Type);
    instance.* = .{};

    const deinit_function = getDeinitFunction(Type);
    deinit_function(instance, &allocator);
}