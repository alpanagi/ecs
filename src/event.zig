const std = @import("std");

const hash = @import("hash.zig").hash;

pub const EventId = struct {
    event: u64,
    subject: ?u64,

    pub fn from(comptime T: type) EventId {
        return .{ .event = hash(T), .subject = null };
    }
};

pub fn Event(comptime T: type) type {
    return struct {
        value: *const T,

        pub fn fromEvent(payload: *const anyopaque) @This() {
            return .{ .value = @ptrCast(@alignCast(payload)) };
        }
    };
}

test "EventId: does not collide with the same event carrying a subject" {
    const allocator = std.testing.allocator;

    var map: std.AutoArrayHashMapUnmanaged(EventId, u32) = .{};
    defer map.deinit(allocator);

    try map.put(allocator, .{ .event = 1, .subject = null }, 10);
    try map.put(allocator, .{ .event = 1, .subject = 0 }, 20);

    try std.testing.expectEqual(2, map.count());
    try std.testing.expectEqual(10, map.get(.{ .event = 1, .subject = null }).?);
    try std.testing.expectEqual(20, map.get(.{ .event = 1, .subject = 0 }).?);
}

test "from: leaves the subject unset" {
    const Explosion = struct { radius: f32 };

    try std.testing.expectEqual(null, EventId.from(Explosion).subject);
}

test "from: keys the event on the type" {
    const Explosion = struct { radius: f32 };

    try std.testing.expectEqual(hash(Explosion), EventId.from(Explosion).event);
}

test "from: distinguishes types with identical fields" {
    const First = struct { value: u8 };
    const Second = struct { value: u8 };

    try std.testing.expect(EventId.from(First).event != EventId.from(Second).event);
}
