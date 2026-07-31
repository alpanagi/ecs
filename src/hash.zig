const std = @import("std");

const seed: u64 = 1234;

pub fn hash(comptime T: type) u64 {
    return std.hash.Wyhash.hash(seed, @typeName(T));
}

test "Returns correct hash for type" {
    const Type = struct { data: u64 };

    try std.testing.expectEqual(87714741122478790, hash(Type));
}
