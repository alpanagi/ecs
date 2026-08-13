const std = @import("std");

pub const DeinitFunction = *const fn (std.mem.Allocator, *anyopaque) void;

pub fn getDeinitFunction(comptime T: type) DeinitFunction {
    return struct {
        fn deinitFunction(allocator: std.mem.Allocator, ptr: *anyopaque) void {
            const instance: *T = @ptrCast(@alignCast(ptr));
            deinitIfPresent(allocator, T, instance);
            allocator.destroy(instance);
        }
    }.deinitFunction;
}

pub fn deinitIfPresent(allocator: std.mem.Allocator, comptime T: type, instance: *T) void {
    if (!std.meta.hasFn(T, "deinit")) return;

    const info = @typeInfo(@TypeOf(T.deinit)).@"fn";
    const name = @typeName(T);
    const error_message = name ++ ".deinit has an unsupported signature, expected fn (*" ++ name ++ ") void or fn (*" ++ name ++ ", std.mem.Allocator) void";

    comptime {
        if (info.return_type != void) @compileError(error_message);

        if (info.params.len == 1 or info.params.len == 2) {
            const Self = info.params[0].type orelse @compileError(error_message);
            if (Self != *T and Self != *const T) @compileError(error_message);
        }

        if (info.params.len == 2) {
            const Allocator = info.params[1].type orelse @compileError(error_message);
            if (Allocator != std.mem.Allocator) @compileError(error_message);
        }
    }

    switch (info.params.len) {
        1 => instance.deinit(),
        2 => instance.deinit(allocator),
        else => @compileError(error_message),
    }
}

test "getDeinitFunction: calls a one argument deinit and frees the instance" {
    const Type = struct {
        allocator: std.mem.Allocator,
        owned: []u8,

        pub fn deinit(self: *@This()) void {
            self.allocator.free(self.owned);
        }
    };

    const allocator = std.testing.allocator;
    const instance = try allocator.create(Type);
    instance.* = .{ .allocator = allocator, .owned = try allocator.alloc(u8, 16) };

    const deinit_function = getDeinitFunction(Type);
    deinit_function(allocator, instance);
}

test "getDeinitFunction: hands the allocator to a two argument deinit" {
    const Type = struct {
        owned: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.owned);
        }
    };

    const allocator = std.testing.allocator;
    const instance = try allocator.create(Type);
    instance.* = .{ .owned = try allocator.alloc(u8, 16) };

    const deinit_function = getDeinitFunction(Type);
    deinit_function(allocator, instance);
}

test "getDeinitFunction: frees the instance when deinit is absent" {
    const Type = struct {
        owned: []u8,
    };

    const allocator = std.testing.allocator;
    const owned = try allocator.alloc(u8, 16);
    defer allocator.free(owned);

    const instance = try allocator.create(Type);
    instance.* = .{ .owned = owned };

    const deinit_function = getDeinitFunction(Type);
    deinit_function(allocator, instance);
}

test "getDeinitFunction: frees a non container type" {
    const allocator = std.testing.allocator;
    const instance = try allocator.create(u32);
    instance.* = 7;

    const deinit_function = getDeinitFunction(u32);
    deinit_function(allocator, instance);
}

test "getDeinitFunction: calls deinit on a zero sized type" {
    const Type = struct {
        var count: usize = 0;

        pub fn deinit(_: *@This()) void {
            count += 1;
        }
    };

    const allocator = std.testing.allocator;
    const instance = try allocator.create(Type);
    instance.* = .{};

    const deinit_function = getDeinitFunction(Type);
    deinit_function(allocator, instance);

    try std.testing.expectEqual(0, @sizeOf(Type));
    try std.testing.expectEqual(1, Type.count);
}

test "deinitIfPresent: runs deinit without freeing the instance" {
    const Type = struct {
        owned: []u8,

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.owned);
        }
    };

    const allocator = std.testing.allocator;
    const instance = try allocator.create(Type);
    defer allocator.destroy(instance);
    instance.* = .{ .owned = try allocator.alloc(u8, 16) };

    deinitIfPresent(allocator, Type, instance);
}

test "deinitIfPresent: calls a deinit taking a const self" {
    const Type = struct {
        var count: usize = 0;

        pub fn deinit(_: *const @This()) void {
            count += 1;
        }
    };

    var instance: Type = .{};
    deinitIfPresent(std.testing.allocator, Type, &instance);

    try std.testing.expectEqual(1, Type.count);
}

test "deinitIfPresent: ignores a type without deinit" {
    var value: u32 = 7;
    deinitIfPresent(std.testing.allocator, u32, &value);

    try std.testing.expectEqual(7, value);
}
