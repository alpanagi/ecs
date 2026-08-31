const std = @import("std");

const deinit_function_name = "deinit";

pub fn validate(Type: type) bool {
    const error_message = "Does not implement Deinit protocol: " ++ @typeName(Type);

    if (@typeInfo(Type) != .@"struct") return false;
    if (!std.meta.hasFn(Type, deinit_function_name)) return false;

    const deinit_info = @typeInfo(@TypeOf(@field(Type, deinit_function_name))).@"fn";
    if (deinit_info.return_type != void) @compileError(error_message);
    if (deinit_info.params.len != 2) @compileError(error_message);
    if (deinit_info.params[0].type != *Type) @compileError(error_message);
    if (deinit_info.params[1].type != std.mem.Allocator) @compileError(error_message);

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
