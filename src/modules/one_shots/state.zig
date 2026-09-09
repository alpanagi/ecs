const std = @import("std");

const Thunk = @import("../../core/run_system.zig").Thunk;

const createSystemThunk = @import("../../core/run_system.zig").createSystemThunk;
const panicOom = @import("../../utils/panic.zig").panicOom;

pub const OneShotsState = struct {
    pending_systems: std.ArrayList(Thunk) = .empty,

    pub fn deinit(self: *OneShotsState, allocator: std.mem.Allocator) void {
        self.pending_systems.deinit(allocator);
    }

    pub fn add(self: *OneShotsState, allocator: std.mem.Allocator, system: anytype) void {
        self.pending_systems.append(allocator, createSystemThunk(system)) catch
            panicOom(@This(), @src());
    }
};
