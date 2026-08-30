const std = @import("std");

const deinit_function_name = "deinit";

pub fn validate(T: type) bool {
    const error_message = "Does not implement Deinit protocol: " ++ @typeName(T);

    if (@typeInfo(T) != .@"struct") return false;
    if (!std.meta.hasFn(T, deinit_function_name)) return false;

    const deinit_info = @typeInfo(@TypeOf(@field(T, deinit_function_name))).@"fn";
    if (deinit_info.return_type != void) @compileError(error_message);

    const params = deinit_info.params;
    if (params.len != 2) @compileError(error_message);
    if (params[0].type != *T) @compileError(error_message);
    if (params[1].type != std.mem.Allocator) @compileError(error_message);

    return true;
}

test "validate: accepts a valid deinit" {
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
