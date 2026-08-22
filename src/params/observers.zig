const event_protocol = @import("../protocols/event.zig");
const std = @import("std");

const EventId = @import("../events/event_id.zig").EventId;
const eventId = @import("../events/event_id.zig").eventId;
const ObserverEntry = @import("../erasure/system_entry.zig").ObserverEntry;
const World = @import("../core/world.zig").World;

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

    fn queue(
        self: *ObserversState,
        allocator: std.mem.Allocator,
        event_id: EventId,
        entry: ObserverEntry,
    ) void {
        self.pending.pushBack(allocator, .{
            .event_id = event_id,
            .entry = entry,
        }) catch panicOom("ObserversState.queue");
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
        if (self.observers.get(eventIdOf(event))) |entries| {
            for (entries.items) |entry| entry.run(allocator, world, &owned);
        }
        getDeinitFunction(@TypeOf(event))(allocator, &owned);
    }
};

const Registration = struct {
    event_id: EventId,
    entry: ObserverEntry,
};

fn eventIdOf(event: anytype) EventId {
    const Payload = @TypeOf(event);
    if (comptime !event_protocol.validate(Payload)) return eventId(Payload);

    return event.id();
}

test "dispatchOwnedEvent: runs a registered observer with the event data" {
    const Event = @import("views/event.zig").Event;

    const Damage = struct { amount: u32 };
    const TestState = struct {
        var seen: u32 = 0;
    };
    const observer = struct {
        fn call(event: Event(Damage)) void {
            TestState.seen = event.value.amount;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.observers.add(std.testing.allocator, eventId(Damage), buildObserverEntry(observer, null));

    const damage = Damage{ .amount = 10 };
    world.observers.dispatchOwnedEvent(std.testing.allocator, &world, damage);

    try std.testing.expectEqual(10, TestState.seen);
}

test "dispatchOwnedEvent: runs a plugin observer through its bound plugin" {
    const Event = @import("views/event.zig").Event;

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
    world.observers.add(std.testing.allocator, eventId(Damage), buildObserverEntry(Plugin.onDamage, &plugin));

    world.observers.dispatchOwnedEvent(std.testing.allocator, &world, Damage{ .amount = 3 });
    world.observers.dispatchOwnedEvent(std.testing.allocator, &world, Damage{ .amount = 4 });

    try std.testing.expectEqual(7, plugin.total);
}

test "dispatchOwnedEvent: runs observers for the same event id in registration order" {
    const Event = @import("views/event.zig").Event;

    const Damage = struct { amount: u32 };
    const TestState = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: Event(Damage)) void {
            TestState.calls[TestState.count] = 1;
            TestState.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: Event(Damage)) void {
            TestState.calls[TestState.count] = 2;
            TestState.count += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.observers.add(std.testing.allocator, eventId(Damage), buildObserverEntry(a, null));
    world.observers.add(std.testing.allocator, eventId(Damage), buildObserverEntry(b, null));

    world.observers.dispatchOwnedEvent(std.testing.allocator, &world, Damage{ .amount = 1 });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &TestState.calls);
}

test "dispatchOwnedEvent: does not run observers registered for a different event id" {
    const Event = @import("views/event.zig").Event;

    const Damage = struct { amount: u32 };
    const Healing = struct { amount: u32 };
    const TestState = struct {
        var damage_calls: usize = 0;
    };
    const onDamage = struct {
        fn call(_: Event(Damage)) void {
            TestState.damage_calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.observers.add(std.testing.allocator, eventId(Damage), buildObserverEntry(onDamage, null));

    world.observers.dispatchOwnedEvent(std.testing.allocator, &world, Healing{ .amount = 5 });

    try std.testing.expectEqual(0, TestState.damage_calls);
}

test "dispatchOwnedEvent: runs nothing when no observer is registered for the event id" {
    const Damage = struct { amount: u32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.observers.dispatchOwnedEvent(std.testing.allocator, &world, Damage{ .amount = 1 });
}

test "dispatchOwnedEvent: routes on the id the event reports" {
    const ComponentAdded = @import("../events/component.zig").ComponentAdded;
    const componentAdded = @import("../events/component.zig").componentAdded;
    const Event = @import("views/event.zig").Event;

    const componentId = @import("../core/component.zig").componentId;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const TestState = struct {
        var position_calls: usize = 0;
        var velocity_calls: usize = 0;
    };
    TestState.position_calls = 0;
    TestState.velocity_calls = 0;

    const onPosition = struct {
        fn call(_: Event(ComponentAdded)) void {
            TestState.position_calls += 1;
        }
    }.call;
    const onVelocity = struct {
        fn call(_: Event(ComponentAdded)) void {
            TestState.velocity_calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.observers.add(std.testing.allocator, componentAdded(Position), buildObserverEntry(onPosition, null));
    world.observers.add(std.testing.allocator, componentAdded(Velocity), buildObserverEntry(onVelocity, null));

    const event = ComponentAdded{ .entity = .{ .id = 0, .generation = 0 }, .component_id = componentId(Position) };
    world.observers.dispatchOwnedEvent(std.testing.allocator, &world, event);

    try std.testing.expectEqual(1, TestState.position_calls);
    try std.testing.expectEqual(0, TestState.velocity_calls);
}

test "queue: defers registration until flush" {
    const componentAdded = @import("../events/component.zig").componentAdded;

    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };
    const Position = struct { x: f32, y: f32 };
    const entry: ObserverEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator, _: *const anyopaque) void {}
    }.call };

    var registry = Observers.State.init();
    defer registry.deinit(allocator);

    var queue = Observers.State.init();
    defer queue.deinit(allocator);

    registry.queue(allocator, eventId(Damage), entry);
    registry.queue(allocator, componentAdded(Position), entry);
    try std.testing.expectEqual(0, registry.observers.count());

    registry.flushPending(allocator);

    try std.testing.expectEqual(2, registry.observers.count());
    try std.testing.expectEqual(1, registry.observers.get(eventId(Damage)).?.items.len);
    try std.testing.expectEqual(1, registry.observers.get(componentAdded(Position)).?.items.len);
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
    registry.queue(allocator, eventId(Damage), entry);
    queue.deinit(allocator);

    try std.testing.expectEqual(0, registry.observers.count());
}

test "dispatchOwnedEvent: runs a registered observer" {
    const Event = @import("views/event.zig").Event;

    const Damage = struct { amount: u32 };
    const TestState = struct {
        var seen: u32 = 0;
    };
    const onDamage = struct {
        fn call(event: Event(Damage)) void {
            TestState.seen = event.value.amount;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.observers.add(std.testing.allocator, eventId(Damage), buildObserverEntry(onDamage, null));
    Observers.fromWorld(std.testing.allocator, &world).dispatchOwnedEvent(std.testing.allocator, Damage{ .amount = 7 });

    try std.testing.expectEqual(7, TestState.seen);
}

test "dispatchOwnedEvent: dispatches synchronously through Observers" {
    const Event = @import("views/event.zig").Event;
    const Systems = @import("systems.zig").Systems;

    const allocator = std.testing.allocator;

    const Damage = struct { amount: u32 };

    const TestState = struct {
        var seen: u32 = 0;
        var ran_before_system_returned: bool = false;
    };
    TestState.seen = 0;
    TestState.ran_before_system_returned = false;

    const onDamage = struct {
        fn call(event: Event(Damage)) void {
            TestState.seen = event.value.amount;
        }
    }.call;
    const system = struct {
        fn call(observers: Observers) void {
            observers.dispatchOwnedEvent(allocator, Damage{ .amount = 7 });
            TestState.ran_before_system_returned = TestState.seen == 7;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, eventId(Damage), buildObserverEntry(onDamage, null));
    Systems.fromWorld(allocator, &world).add(allocator, "update", system, null);

    world.runSystems(allocator);

    try std.testing.expectEqual(7, TestState.seen);
    try std.testing.expect(TestState.ran_before_system_returned);
}

test "dispatchOwnedEvent: deinits the event once after every observer has seen it" {
    const Event = @import("views/event.zig").Event;

    const allocator = std.testing.allocator;

    const TestState = struct {
        var deinits: usize = 0;
        var first: usize = 0;
        var second: usize = 0;
    };
    const Message = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            TestState.deinits += 1;
            event_allocator.free(self.text);
        }
    };
    TestState.deinits = 0;
    TestState.first = 0;
    TestState.second = 0;

    const onFirst = struct {
        fn call(event: Event(Message)) void {
            TestState.first = event.value.text.len;
        }
    }.call;
    const onSecond = struct {
        fn call(event: Event(Message)) void {
            TestState.second = event.value.text.len;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, eventId(Message), buildObserverEntry(onFirst, null));
    world.observers.add(allocator, eventId(Message), buildObserverEntry(onSecond, null));

    Observers.fromWorld(allocator, &world).dispatchOwnedEvent(allocator, Message{ .text = try allocator.alloc(u8, 4) });

    try std.testing.expectEqual(4, TestState.first);
    try std.testing.expectEqual(4, TestState.second);
    try std.testing.expectEqual(1, TestState.deinits);
}

test "dispatchOwnedEvent: deinits an event that no observer is listening for" {
    const allocator = std.testing.allocator;

    const TestState = struct {
        var deinits: usize = 0;
    };
    const Message = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            TestState.deinits += 1;
            event_allocator.free(self.text);
        }
    };
    TestState.deinits = 0;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Observers.fromWorld(allocator, &world).dispatchOwnedEvent(allocator, Message{ .text = try allocator.alloc(u8, 4) });

    try std.testing.expectEqual(1, TestState.deinits);
}

test "dispatchOwnedEvent: leaves an event without deinit untouched" {
    const Event = @import("views/event.zig").Event;

    const allocator = std.testing.allocator;

    const Message = struct { text: []u8 };

    const TestState = struct {
        var seen: usize = 0;
    };
    TestState.seen = 0;

    const onMessage = struct {
        fn call(event: Event(Message)) void {
            TestState.seen = event.value.text.len;
        }
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, eventId(Message), buildObserverEntry(onMessage, null));

    const text = try allocator.alloc(u8, 4);
    defer allocator.free(text);

    Observers.fromWorld(allocator, &world).dispatchOwnedEvent(allocator, Message{ .text = text });

    try std.testing.expectEqual(4, TestState.seen);
}

test "dispatchOwnedEvent: deinits both events when an observer dispatches another" {
    const Event = @import("views/event.zig").Event;

    const allocator = std.testing.allocator;

    const TestState = struct {
        var order: [2]u8 = .{ 0, 0 };
        var deinits: usize = 0;
    };
    TestState.order = .{ 0, 0 };
    TestState.deinits = 0;

    const Inner = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            TestState.order[TestState.deinits] = 'i';
            TestState.deinits += 1;
            event_allocator.free(self.text);
        }
    };
    const Outer = struct {
        text: []u8,

        pub fn deinit(self: *@This(), event_allocator: std.mem.Allocator) void {
            TestState.order[TestState.deinits] = 'o';
            TestState.deinits += 1;
            event_allocator.free(self.text);
        }
    };

    const onOuter = struct {
        fn call(observers: Observers, inner: std.mem.Allocator, _: Event(Outer)) void {
            const text = inner.alloc(u8, 8) catch panicOom("onOuter");
            observers.dispatchOwnedEvent(inner, Inner{ .text = text });
        }
    }.call;
    const onInner = struct {
        fn call(_: Event(Inner)) void {}
    }.call;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.observers.add(allocator, eventId(Outer), buildObserverEntry(onOuter, null));
    world.observers.add(allocator, eventId(Inner), buildObserverEntry(onInner, null));

    Observers.fromWorld(allocator, &world).dispatchOwnedEvent(allocator, Outer{ .text = try allocator.alloc(u8, 4) });

    try std.testing.expectEqual(2, TestState.deinits);
    try std.testing.expectEqual([2]u8{ 'i', 'o' }, TestState.order);
}
