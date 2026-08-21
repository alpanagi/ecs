const std = @import("std");

const World = @import("../core/world.zig").World;
const Event = @import("views/event.zig").Event;
const EventId = @import("../core/event_id.zig").EventId;
const ObserverEntry = @import("../erasure/system_entry.zig").ObserverEntry;
const buildObserverEntry = @import("../erasure/system_entry.zig").buildObserverEntry;
const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const panicOom = @import("../utils.zig").panicOom;

pub const Observers = struct {
    pub const State = ObserversState;

    state: *State,
    world: *World,

    pub fn fromWorld(_: std.mem.Allocator, world: *World) Observers {
        return .{ .state = &world.observers, .world = world };
    }

    pub fn add(
        self: Observers,
        allocator: std.mem.Allocator,
        event_id: EventId,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.state.queue(allocator, event_id, buildObserverEntry(function, plugin));
    }

    pub fn dispatchOwnedEvent(self: Observers, allocator: std.mem.Allocator, event: anytype) void {
        self.state.dispatchOwnedEvent(allocator, self.world, event);
    }
};

const ObserversState = struct {
    observers: std.AutoArrayHashMapUnmanaged(EventId, std.ArrayList(ObserverEntry)) = .{},
    pending: std.Deque(Registration) = .empty,

    pub fn init() ObserversState {
        return .{};
    }

    pub fn deinit(self: *ObserversState, allocator: std.mem.Allocator) void {
        for (self.observers.values()) |*entries| entries.deinit(allocator);
        self.observers.deinit(allocator);
        self.pending.deinit(allocator);
    }

    pub fn add(
        self: *ObserversState,
        allocator: std.mem.Allocator,
        event_id: EventId,
        entry: ObserverEntry,
    ) void {
        const gop = self.observers.getOrPut(allocator, event_id) catch
            panicOom("Observers.State.add");
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(allocator, entry) catch panicOom("Observers.State.add");
    }

    pub fn queue(
        self: *ObserversState,
        allocator: std.mem.Allocator,
        event_id: EventId,
        entry: ObserverEntry,
    ) void {
        self.pending.pushBack(allocator, .{
            .event_id = event_id,
            .entry = entry,
        }) catch panicOom("Observers.State.queue");
    }

    pub fn flushPending(self: *ObserversState, allocator: std.mem.Allocator) void {
        while (self.pending.popFront()) |registration| {
            self.add(allocator, registration.event_id, registration.entry);
        }
    }

    pub fn dispatchOwnedEvent(
        self: *const ObserversState,
        allocator: std.mem.Allocator,
        world: *World,
        event: anytype,
    ) void {
        var owned = event;
        self.dispatch(allocator, world, EventId.from(@TypeOf(event)), &owned);
        getDeinitFunction(@TypeOf(event))(allocator, &owned);
    }

    pub fn dispatch(
        self: *const ObserversState,
        allocator: std.mem.Allocator,
        world: *World,
        event_id: EventId,
        payload: *const anyopaque,
    ) void {
        if (self.observers.get(event_id)) |entries| {
            for (entries.items) |entry| entry.run(allocator, world, payload);
        }
    }
};

const Registration = struct {
    event_id: EventId,
    entry: ObserverEntry,
};

test "dispatch: runs a registered observer with the event data" {
    const Damage = struct { amount: u32 };
    const State = struct {
        var seen: u32 = 0;
    };
    const observer = struct {
        fn call(event: Event(Damage)) void {
            State.seen = event.value.amount;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.observers.add(std.testing.allocator, EventId.from(Damage), buildObserverEntry(observer, null));

    const damage = Damage{ .amount = 10 };
    world.observers.dispatch(std.testing.allocator, &world, EventId.from(Damage), &damage);

    try std.testing.expectEqual(10, State.seen);
}

test "dispatch: runs a plugin observer through its bound plugin" {
    const Damage = struct { amount: u32 };
    const Plugin = struct {
        total: u32 = 0,

        fn onDamage(self: *@This(), event: Event(Damage)) void {
            self.total += event.value.amount;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    var plugin = Plugin{};
    world.observers.add(std.testing.allocator, EventId.from(Damage), buildObserverEntry(Plugin.onDamage, &plugin));

    world.observers.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 3 });
    world.observers.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 4 });

    try std.testing.expectEqual(7, plugin.total);
}

test "dispatch: runs observers for the same event id in registration order" {
    const Damage = struct { amount: u32 };
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: Event(Damage)) void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: Event(Damage)) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.observers.add(std.testing.allocator, EventId.from(Damage), buildObserverEntry(a, null));
    world.observers.add(std.testing.allocator, EventId.from(Damage), buildObserverEntry(b, null));

    world.observers.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 1 });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "dispatch: does not run observers registered for a different event id" {
    const Damage = struct { amount: u32 };
    const Healing = struct { amount: u32 };
    const State = struct {
        var damage_calls: usize = 0;
    };
    const onDamage = struct {
        fn call(_: Event(Damage)) void {
            State.damage_calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.observers.add(std.testing.allocator, EventId.from(Damage), buildObserverEntry(onDamage, null));

    world.observers.dispatch(std.testing.allocator, &world, EventId.from(Healing), &Healing{ .amount = 5 });

    try std.testing.expectEqual(0, State.damage_calls);
}

test "dispatch: runs nothing when no observer is registered for the event id" {
    const Damage = struct { amount: u32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.observers.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 1 });
}

test "dispatch: routes on the subject as well as the event" {
    const component = @import("../core/lifecycle.zig").component;
    const ComponentAdded = @import("../core/lifecycle.zig").ComponentAdded;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const State = struct {
        var position_calls: usize = 0;
        var velocity_calls: usize = 0;
    };
    State.position_calls = 0;
    State.velocity_calls = 0;

    const onPosition = struct {
        fn call(_: Event(ComponentAdded)) void {
            State.position_calls += 1;
        }
    }.call;
    const onVelocity = struct {
        fn call(_: Event(ComponentAdded)) void {
            State.velocity_calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.observers.add(std.testing.allocator, component.added(Position), buildObserverEntry(onPosition, null));
    world.observers.add(std.testing.allocator, component.added(Velocity), buildObserverEntry(onVelocity, null));

    const event = ComponentAdded{ .entity = .{ .id = 0, .generation = 0 }, .component = 0 };
    world.observers.dispatch(std.testing.allocator, &world, component.added(Position), &event);

    try std.testing.expectEqual(1, State.position_calls);
    try std.testing.expectEqual(0, State.velocity_calls);
}

test "State.queue: defers registration until flush" {
    const allocator = std.testing.allocator;

    const component = @import("../core/lifecycle.zig").component;

    const Damage = struct { amount: u32 };
    const Position = struct { x: f32, y: f32 };
    const entry: ObserverEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator, _: *const anyopaque) void {}
    }.call };

    var registry = Observers.State.init();
    defer registry.deinit(allocator);

    var queue = Observers.State.init();
    defer queue.deinit(allocator);

    registry.queue(allocator, EventId.from(Damage), entry);
    registry.queue(allocator, component.added(Position), entry);
    try std.testing.expectEqual(0, registry.observers.count());

    registry.flushPending(allocator);

    try std.testing.expectEqual(2, registry.observers.count());
    try std.testing.expectEqual(1, registry.observers.get(EventId.from(Damage)).?.items.len);
    try std.testing.expectEqual(1, registry.observers.get(component.added(Position)).?.items.len);
}

test "Observers.State.deinit: discards unflushed commands without applying them" {
    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };
    const entry: ObserverEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator, _: *const anyopaque) void {}
    }.call };

    var registry = Observers.State.init();
    defer registry.deinit(allocator);

    var queue = Observers.State.init();
    registry.queue(allocator, EventId.from(Damage), entry);
    queue.deinit(allocator);

    try std.testing.expectEqual(0, registry.observers.count());
}
