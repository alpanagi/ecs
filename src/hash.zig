const std = @import("std");

const seed: u64 = 1234;

pub fn hash(comptime T: type) u64 {
    return hashBytes(@typeName(T));
}

pub fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

test "hash uses Wyhash" {
    const Type = struct { data: u64 };

    try std.testing.expectEqual(1622734371899143350, hash(Type));
}

test "hashBytes uses Wyhash" {
    try std.testing.expectEqual(1717878719255034275, hashBytes("physics"));
}
