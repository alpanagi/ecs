const std = @import("std");
const parameter_protocol = @import("parameter.zig");

pub const ValidationOptions = struct {
    ignore: []const type = &.{},
    reject: []const type = &.{},
};

pub fn validate(Type: type, comptime options: ValidationOptions) bool {
    const function_info = switch (@typeInfo(Type)) {
        .@"fn" => |function| function,
        else => return false,
    };

    if (function_info.return_type != void) return false;

    parameters: inline for (function_info.params) |parameter| {
        inline for (options.ignore) |TypeToIgnore| {
            if (parameter.type == TypeToIgnore) continue :parameters;
        }

        inline for (options.reject) |TypeToReject| {
            if (parameter.type == TypeToReject) return false;
        }

        if (parameter.type == null) return false;
        if (parameter.type == std.mem.Allocator) continue;
        if (comptime !parameter_protocol.validate(parameter.type.?)) return false;
    }

    return true;
}

test "validate: accepts a function with an allocator parameter" {
    const function = struct {
        pub fn function(_: std.mem.Allocator) void {}
    }.function;

    try std.testing.expect(validate(@TypeOf(function), .{}));
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

    try std.testing.expect(validate(@TypeOf(function), .{}));
}

test "validate: accepts a function with no parameters" {
    const function = struct {
        pub fn function() void {}
    }.function;

    try std.testing.expect(validate(@TypeOf(function), .{}));
}

test "validate: rejects a function that doesn't return void" {
    const function = struct {
        pub fn function() !void {}
    }.function;

    try std.testing.expect(!validate(@TypeOf(function), .{}));
}

test "validate: rejects a generic parameter" {
    const function = struct {
        pub fn function(_: anytype) void {}
    }.function;

    try std.testing.expect(!validate(@TypeOf(function), .{}));
}

test "validate: rejects a parameter that is not fromWorld" {
    const Type = struct { data: u32 };

    const function = struct {
        pub fn function(_: Type) void {}
    }.function;

    try std.testing.expect(!validate(@TypeOf(function), .{}));
}

test "validate: rejects a type that is not a function" {
    const Data = struct { data: u32 };

    try std.testing.expect(!validate(Data, .{}));
}

test "validate: accepts an otherwise invalid type if it is in the ignore list" {
    const function = struct {
        pub fn function(_: u32) void {}
    }.function;

    try std.testing.expect(validate(@TypeOf(function), .{ .ignore = &.{u32} }));
}

test "validate: returns false for a valid type in the reject list" {
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

    try std.testing.expect(!validate(@TypeOf(function), .{ .reject = &.{Parameter} }));
}
