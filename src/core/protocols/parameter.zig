const std = @import("std");

const World = @import("../world.zig").World;

const from_world_function_name = "fromWorld";

pub fn validate(Type: type) bool {
    const error_message = "Does not implement Parameter protocol: " ++ @typeName(Type);

    if (@typeInfo(Type) != .@"struct") return false;
    if (!std.meta.hasFn(Type, from_world_function_name)) return false;

    const from_world_info = @typeInfo(@TypeOf(@field(Type, from_world_function_name))).@"fn";
    if (from_world_info.return_type != Type) @compileError(error_message);
    if (from_world_info.params.len != 2) @compileError(error_message);
    if (from_world_info.params[0].type != std.mem.Allocator) @compileError(error_message);
    if (from_world_info.params[1].type != *World) @compileError(error_message);

    return true;
}

test "validate: accepts a struct that implements fromWorld" {
    const Data = struct {
        data: u32,

        pub fn fromWorld(_: std.mem.Allocator, _: *World) @This() {
            return .{ .data = 11 };
        }
    };

    try std.testing.expect(validate(Data));
}

test "validate: rejects a struct that doesn't implement fromWorld" {
    const Data = struct { data: u32 };
    try std.testing.expect(!validate(Data));
}

test "validate: rejects a non-struct parameter" {
    try std.testing.expect(!validate(u32));
}
