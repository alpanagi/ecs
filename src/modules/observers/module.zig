const std = @import("std");

const ObserversState = @import("state.zig").ObserversState;
const Resources = @import("../resources/module.zig").Resources;

pub const Event = @import("event_parameter.zig").Event;
pub const Events = @import("events_parameter.zig").Events;
pub const Observers = @import("observers_parameter.zig").Observers;

pub fn setup(allocator: std.mem.Allocator, resources: Resources) void {
    var state = ObserversState{};
    resources.addOwned(allocator, &state);
}
