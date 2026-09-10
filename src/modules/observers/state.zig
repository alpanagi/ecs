const std = @import("std");
const system_protocol = @import("../../core/protocols/system.zig");

const Event = @import("event_parameter.zig").Event;
const EventId = @import("event_id.zig").EventId;
const World = @import("../../core/world.zig").World;

const panicOom = @import("../../utils/panic.zig").panicOom;

pub const ObserversState = struct {
    observers: std.AutoHashMapUnmanaged(EventId, std.ArrayList(ObserverThunk)) = .empty,

    pub fn deinit(self: *ObserversState, allocator: std.mem.Allocator) void {
        var value_iterator = self.observers.valueIterator();
        while (value_iterator.next()) |observer_list| observer_list.deinit(allocator);
        self.observers.deinit(allocator);
    }

    pub fn add(
        self: *ObserversState,
        allocator: std.mem.Allocator,
        EventType: type,
        system: anytype,
    ) void {
        const thunk = createObserverThunk(EventType, system);
        const gop = self.observers.getOrPut(allocator, EventId.fromType(EventType)) catch
            panicOom(@This(), @src());
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(allocator, thunk) catch panicOom(@This(), @src());
    }

    pub fn dispatch(
        self: *ObserversState,
        allocator: std.mem.Allocator,
        world: *World,
        event: anytype,
    ) void {
        const PointerType = @TypeOf(event);
        const pointer_type_info = @typeInfo(PointerType);
        if (pointer_type_info != .pointer or pointer_type_info.pointer.size != .one)
            @compileError("Dispatch requires pointer to an event, found: " ++
                @typeName(PointerType));

        const EventType = pointer_type_info.pointer.child;

        const observers = self.observers.getPtr(EventId.fromType(EventType)) orelse return;
        for (observers.items) |observer| observer(allocator, world, event);
    }
};

const ObserverThunk = *const fn (std.mem.Allocator, *World, *const anyopaque) void;

fn createObserverThunk(EventType: type, system: anytype) ObserverThunk {
    const SystemType = @TypeOf(system);

    if (comptime !system_protocol.validate(SystemType, .{ .ignore = &.{Event(EventType)} }))
        @compileError("Does not implement System protocol: " ++ @typeName(SystemType));

    return struct {
        pub fn function(allocator: std.mem.Allocator, world: *World, event: *const anyopaque) void {
            const typed_event: *const EventType = @ptrCast(@alignCast(event));
            runObserverSystem(allocator, world, typed_event, system);
        }
    }.function;
}

fn runObserverSystem(
    allocator: std.mem.Allocator,
    world: *World,
    event: anytype,
    system: anytype,
) void {
    const SystemType = @TypeOf(system);
    const EventType = @typeInfo(@TypeOf(event)).pointer.child;

    var arguments: std.meta.ArgsTuple(SystemType) = undefined;
    inline for (&arguments) |*argument| {
        const ArgumentType = @TypeOf(argument.*);

        switch (ArgumentType) {
            std.mem.Allocator => argument.* = allocator,
            Event(EventType) => argument.* = .{ .value = event },
            else => argument.* = ArgumentType.fromWorld(allocator, world),
        }
    }

    @call(.auto, system, arguments);
}

test "dispatch: runs observers for a specific event, passing the event data" {
    const Resource = @import("../resources/module.zig").Resource;

    const TestState = struct {
        var observer_calls: u32 = 0;
        var data_read: ?u32 = null;
    };

    const Type = struct { data: u32 };

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const system = struct {
        pub fn function(event: Event(Type)) void {
            TestState.observer_calls += 1;
            TestState.data_read = event.value.data;
        }
    }.function;

    const event = Type{ .data = 12 };

    const state = Resource(ObserversState).fromWorld(allocator, &world).value;
    state.add(allocator, Type, system);
    state.dispatch(allocator, &world, &event);

    try std.testing.expectEqual(1, TestState.observer_calls);
    try std.testing.expectEqual(12, TestState.data_read);
}

test "dispatch: runs successfully on unknown event" {
    const Resource = @import("../resources/module.zig").Resource;

    const Type = struct { data: u32 };

    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const event = Type{ .data = 12 };

    const state = Resource(ObserversState).fromWorld(allocator, &world).value;
    state.dispatch(allocator, &world, &event);
}
