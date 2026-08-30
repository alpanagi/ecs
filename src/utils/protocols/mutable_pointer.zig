const std = @import("std");

pub fn validate(T: type) bool {
    const type_info = @typeInfo(T);
    const pointer = switch (type_info) {
        .pointer => |pointer| pointer,
        else => return false,
    };

    const child_info = @typeInfo(pointer.child);
    if (child_info != .@"struct") return false;

    return true;
}

test "validate: accepts a pointer to a struct" {
    const Data = struct { data: u32 };
    var data: Data = .{ .data = 11 };

    try std.testing.expect(validate(@TypeOf(&data)));
}

test "validate: rejects a struct value" {
    const Data = struct { data: u32 };
    const data: Data = .{ .data = 12 };

    try std.testing.expect(!validate(@TypeOf(data)));
}

test "validate: rejects a pointer to a non-struct" {
    var data: u32 = 13;

    try std.testing.expect(!validate(@TypeOf(&data)));
}

test "validate: rejects a pointer to a slice" {
    var data: [2]u32 = .{ 14, 15 };

    try std.testing.expect(!validate(@TypeOf(&data)));
}
