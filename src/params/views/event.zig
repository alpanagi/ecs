pub fn Event(comptime T: type) type {
    return struct {
        value: *const T,

        pub fn fromEvent(payload: *const anyopaque) @This() {
            return .{ .value = @ptrCast(@alignCast(payload)) };
        }
    };
}
