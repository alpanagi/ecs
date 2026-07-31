const std = @import("std");

pub fn sortMultiple(keys: anytype, others: anytype) void {
    const KeyType = @typeInfo(@TypeOf(keys)).pointer.child;

    const SortContext = struct {
        keys: @TypeOf(keys),
        others: @TypeOf(others),

        pub fn lessThan(self: @This(), a: usize, b: usize) bool {
            return self.keys[a] < self.keys[b];
        }

        pub fn swap(self: @This(), a: usize, b: usize) void {
            std.mem.swap(KeyType, &self.keys[a], &self.keys[b]);
            inline for (self.others) |other| {
                std.mem.swap(@TypeOf(other[0]), &other[a], &other[b]);
            }
        }
    };

    std.mem.sortUnstableContext(0, keys.len, SortContext{ .keys = keys, .others = others });
}

test "Sorts 2 parallel arrays correctly" {
    var keys_arr = [_]u64{ 5, 2, 4, 3, 1 };
    var other_arr = [_]f32{ 12.2, 43.1, 5.6, 66.4, 9.0 };

    const keys: []u64 = &keys_arr;
    const other: []f32 = &other_arr;

    const expected_keys = [_]u64{ 1, 2, 3, 4, 5 };
    const expected_other = [_]f32{ 9.0, 43.1, 66.4, 5.6, 12.2 };

    sortMultiple(keys, .{other});

    try std.testing.expectEqualSlices(u64, &expected_keys, keys);
    try std.testing.expectEqualSlices(f32, &expected_other, other);
}

test "Sorts 3 parallel arrays correctly" {
    var keys_arr = [_]u64{ 5, 2, 4, 3, 1 };
    var other1_arr = [_]f32{ 12.2, 43.1, 5.6, 66.4, 9.0 };
    var other2_arr = [_]u8{ 1, 2, 3, 4, 5 };

    const keys: []u64 = &keys_arr;
    const other1: []f32 = &other1_arr;
    const other2: []u8 = &other2_arr;

    const expected_keys = [_]u64{ 1, 2, 3, 4, 5 };
    const expected_other1 = [_]f32{ 9.0, 43.1, 66.4, 5.6, 12.2 };
    const expected_other2 = [_]u8{ 5, 2, 4, 3, 1 };

    sortMultiple(keys, .{ other1, other2 });

    try std.testing.expectEqualSlices(u64, &expected_keys, keys);
    try std.testing.expectEqualSlices(f32, &expected_other1, other1);
    try std.testing.expectEqualSlices(u8, &expected_other2, other2);
}

test "sortMultiple does nothing on an empty array" {
    var keys_arr = [_]u64{};
    const keys: []u64 = &keys_arr;

    sortMultiple(keys, .{});

    try std.testing.expectEqual(0, keys.len);
}

test "sortMultiple does nothing to an already-sorted single-element array" {
    var keys_arr = [_]u64{42};
    var other_arr = [_]f32{1.5};

    const keys: []u64 = &keys_arr;
    const other: []f32 = &other_arr;

    sortMultiple(keys, .{other});

    try std.testing.expectEqualSlices(u64, &[_]u64{42}, keys);
    try std.testing.expectEqualSlices(f32, &[_]f32{1.5}, other);
}

test "sortMultiple sorts keys when there are no other arrays" {
    var keys_arr = [_]u64{ 5, 2, 4, 3, 1 };
    const keys: []u64 = &keys_arr;

    sortMultiple(keys, .{});

    try std.testing.expectEqualSlices(u64, &[_]u64{ 1, 2, 3, 4, 5 }, keys);
}
