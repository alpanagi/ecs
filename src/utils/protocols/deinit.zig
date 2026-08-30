const std = @import("std");

const deinit_function_name = "deinit";

pub fn validate(T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!std.meta.hasFn(T, deinit_function_name)) return false;

    const deinit_info = @typeInfo(@TypeOf(@field(T, deinit_function_name))).@"fn";
    if (deinit_info.return_type != void) return false;

    const params = switch (deinit_info.params.len) {
        1, 2 => deinit_info.params,
        else => return false,
    };

    if (params[0].type != *T) return false;
    if (params.len == 2 and params[1].type != std.mem.Allocator) return false;

    return true;
}

test "validate: accepts a valid single parameter deinit" {
    const Type = struct {
        pub fn deinit(_: *@This()) void {}
    };

    try std.testing.expect(validate(Type));
}

test "validate: accepts a valid two parameter deinit" {
    const Type = struct {
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
    };

    try std.testing.expect(validate(Type));
}

test "validate: rejects a non-struct type" {
    const Type = [3]u32;

    try std.testing.expect(!validate(Type));
}

test "validate: rejects a type without a deinit" {
    const Type = struct { data: u32 };

    try std.testing.expect(!validate(Type));
}

test "validate: rejects a single parameter deinit with an invalid argument" {
    const Type = struct {
        pub fn deinit(_: u32) void {}
    };

    try std.testing.expect(!validate(Type));
}

test "validate: rejects a two parameter deinit with an invalid second argument" {
    const Type = struct {
        pub fn deinit(_: *@This(), _: u32) void {}
    };

    try std.testing.expect(!validate(Type));
}

test "validate: rejects deinit with invalid return type" {
    const Type = struct {
        pub fn deinit(_: *@This()) !void {}
    };

    try std.testing.expect(!validate(Type));
}

test "validate: rejects deinit with more than 2 parameters" {
    const Type = struct {
        pub fn deinit(_: *@This(), _: std.mem.Allocator, _: *@This()) void {}
    };

    try std.testing.expect(!validate(Type));
}
