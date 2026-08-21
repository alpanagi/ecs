const hash = @import("../erasure/hash.zig").hash;

pub fn resourceId(comptime T: type) u64 {
    return hash(T);
}

test "resourceId: distinguishes types with identical fields" {
    const std = @import("std");

    const First = struct { value: u32 };
    const Second = struct { value: u32 };

    try std.testing.expect(resourceId(First) != resourceId(Second));
}
