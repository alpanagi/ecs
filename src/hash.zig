const std = @import("std");

const seed: u64 = 1234;

pub fn hash(comptime T: type) u64 {
    return comptime hashBytes(@typeName(T));
}

pub fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

test "hash: hashes the type name with Wyhash" {
    const Type = struct { data: u64 };

    try std.testing.expectEqual(1449256646140971360, hash(Type));
}

test "hash: matches hashBytes of the type name" {
    const Type = struct { data: u64 };

    try std.testing.expectEqual(hashBytes(@typeName(Type)), hash(Type));
}

test "hash: distinguishes types with identical fields" {
    const First = struct { data: u64 };
    const Second = struct { data: u64 };

    try std.testing.expect(hash(First) != hash(Second));
}

test "hashBytes: hashes the bytes with Wyhash" {
    try std.testing.expectEqual(1717878719255034275, hashBytes("physics"));
}

test "hashBytes: distinguishes different bytes" {
    try std.testing.expect(hashBytes("physics") != hashBytes("render"));
}

test "hashBytes: returns the same value for equal bytes" {
    var buffer: [7]u8 = "physics".*;

    try std.testing.expectEqual(hashBytes("physics"), hashBytes(&buffer));
}
