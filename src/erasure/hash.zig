const std = @import("std");

const seed: u64 = 1234;

pub fn hash(comptime T: type) u64 {
    return comptime hashBytes(@typeName(T));
}

pub fn hashBytes(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(seed, bytes);
}

test "hash: distinguishes types with identical fields" {
    const First = struct { data: u64 };
    const Second = struct { data: u64 };

    try std.testing.expect(hash(First) != hash(Second));
}
