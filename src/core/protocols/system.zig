const std = @import("std");
const parameter_protocol = @import("parameter.zig");

pub fn validate(Type: type) bool {
    const error_message = "Does not implement System protocol: " ++ @typeName(Type);

    const function_info = switch (@typeInfo(Type)) {
        .@"fn" => |function| function,
        else => return false,
    };

    if (function_info.return_type != void) @compileError(error_message);

    inline for (function_info.params) |parameter| {
        if (parameter.type == std.mem.Allocator) continue;
        if (parameter.type == null) @compileError(error_message);
        if (comptime !parameter_protocol.validate(parameter.type.?)) @compileError(error_message);
    }

    return true;
}

test "validate: accepts a function with an allocator parameter" {
    const function = struct {
        pub fn function(_: std.mem.Allocator) void {}
    }.function;

    try std.testing.expect(validate(@TypeOf(function)));
}

test "validate: accepts a function with a valid parameter" {
    const World = @import("../world.zig").World;

    const Parameter = struct {
        data: u32,

        pub fn fromWorld(_: std.mem.Allocator, _: *World) @This() {
            return .{ .data = 11 };
        }
    };

    const function = struct {
        pub fn function(_: Parameter) void {}
    }.function;

    try std.testing.expect(validate(@TypeOf(function)));
}

test "validate: accepts a function with no parameters" {
    const function = struct {
        pub fn function() void {}
    }.function;

    try std.testing.expect(validate(@TypeOf(function)));
}

test "validate: rejects a type that is not a function" {
    const Data = struct { data: u32 };

    try std.testing.expect(!validate(Data));
}
