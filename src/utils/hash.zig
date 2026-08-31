const std = @import("std");

const seed: u64 = 42;

pub fn hash(T: type) u64 {
    return std.hash.Wyhash.hash(seed, @typeName(T));
}
