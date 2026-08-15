const std = @import("std");

const World = @import("world.zig").World;
const Event = @import("event.zig").Event;
const SystemEntry = @import("system_entry.zig").SystemEntry;
const ObserverEntry = @import("system_entry.zig").ObserverEntry;
const buildSystemEntry = @import("system_entry.zig").buildSystemEntry;
const buildObserverEntry = @import("system_entry.zig").buildObserverEntry;
const EventId = @import("event.zig").EventId;
const panicOom = @import("util.zig").panicOom;

pub const GroupIterator = struct {
    groups: []const std.ArrayList(SystemEntry),
    index: usize = 0,

    pub fn next(self: *GroupIterator) ?[]const SystemEntry {
        if (self.index >= self.groups.len) return null;
        defer self.index += 1;
        return self.groups[self.index].items;
    }
};

pub const SystemRegistry = struct {
    groups: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(SystemEntry)) = .{},
    observers: std.AutoArrayHashMapUnmanaged(EventId, std.ArrayList(ObserverEntry)) = .{},
    one_shot_systems: std.ArrayList(SystemEntry) = .empty,

    pub fn init() SystemRegistry {
        return .{};
    }

    pub fn deinit(self: *SystemRegistry, allocator: std.mem.Allocator) void {
        for (self.groups.values()) |*group| group.deinit(allocator);
        self.groups.deinit(allocator);
        for (self.observers.values()) |*group| group.deinit(allocator);
        self.observers.deinit(allocator);
        self.one_shot_systems.deinit(allocator);
    }

    pub fn addSystemEntry(
        self: *SystemRegistry,
        allocator: std.mem.Allocator,
        group: u64,
        entry: SystemEntry,
    ) void {
        appendEntry(u64, SystemEntry, &self.groups, allocator, group, entry);
    }

    pub fn addOneShotSystemEntry(
        self: *SystemRegistry,
        allocator: std.mem.Allocator,
        entry: SystemEntry,
    ) void {
        self.one_shot_systems.append(allocator, entry) catch panicOom("SystemRegistry.addOneShotSystemEntry");
    }

    pub fn addObserverEntry(
        self: *SystemRegistry,
        allocator: std.mem.Allocator,
        event_id: EventId,
        entry: ObserverEntry,
    ) void {
        appendEntry(EventId, ObserverEntry, &self.observers, allocator, event_id, entry);
    }

    pub fn runOneShotSystems(self: *SystemRegistry, allocator: std.mem.Allocator, world: *World) void {
        for (self.one_shot_systems.items) |entry| entry.run(allocator, world);
        self.one_shot_systems.clearRetainingCapacity();
    }

    pub fn groupIterator(self: *const SystemRegistry) GroupIterator {
        return .{ .groups = self.groups.values() };
    }

    pub fn dispatch(
        self: *const SystemRegistry,
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

fn appendEntry(
    comptime Key: type,
    comptime Entry: type,
    map: *std.AutoArrayHashMapUnmanaged(Key, std.ArrayList(Entry)),
    allocator: std.mem.Allocator,
    key: Key,
    entry: Entry,
) void {
    const gop = map.getOrPut(allocator, key) catch panicOom("SystemRegistry.appendEntry");
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    gop.value_ptr.append(allocator, entry) catch panicOom("SystemRegistry.appendEntry");
}

test "addSystemEntry: creates a group on first use" {
    const system = struct {
        fn call(_: std.mem.Allocator) void {}
    }.call;

    var registry = SystemRegistry.init();
    defer registry.deinit(std.testing.allocator);
    registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(system, null));

    try std.testing.expectEqual(1, registry.groups.count());
    try std.testing.expectEqual(1, registry.groups.get(1).?.items.len);
}

test "addSystemEntry: appends to an existing group in call order" {
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(a, null));
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(b, null));

    world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "addSystemEntry: binds the plugin pointer when provided" {
    const Plugin = struct {
        calls: usize = 0,

        fn update(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    var plugin = Plugin{};
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(Plugin.update, &plugin));

    world.runSystems(std.testing.allocator);
    try std.testing.expectEqual(1, plugin.calls);
}

test "addSystemEntry: preserves group order by first registration" {
    const a = struct {
        fn call(_: std.mem.Allocator) void {}
    }.call;
    const b = struct {
        fn call(_: std.mem.Allocator) void {}
    }.call;

    var registry = SystemRegistry.init();
    defer registry.deinit(std.testing.allocator);
    registry.addSystemEntry(std.testing.allocator, 2, buildSystemEntry(a, null));
    registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(b, null));
    registry.addSystemEntry(std.testing.allocator, 2, buildSystemEntry(b, null));

    try std.testing.expectEqualSlices(u64, &.{ 2, 1 }, registry.groups.keys());
}

test "addOneShotSystemEntry: appends to the one shot systems" {
    const system = struct {
        fn call(_: std.mem.Allocator) void {}
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addOneShotSystemEntry(std.testing.allocator, buildSystemEntry(system, null));

    try std.testing.expectEqual(1, world.system_registry.one_shot_systems.items.len);
}

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

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addObserverEntry(std.testing.allocator, EventId.from(Damage), buildObserverEntry(observer, null));

    const damage = Damage{ .amount = 10 };
    world.system_registry.dispatch(std.testing.allocator, &world, EventId.from(Damage), &damage);

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

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    var plugin = Plugin{};
    world.system_registry.addObserverEntry(std.testing.allocator, EventId.from(Damage), buildObserverEntry(Plugin.onDamage, &plugin));

    world.system_registry.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 3 });
    world.system_registry.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 4 });

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

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addObserverEntry(std.testing.allocator, EventId.from(Damage), buildObserverEntry(a, null));
    world.system_registry.addObserverEntry(std.testing.allocator, EventId.from(Damage), buildObserverEntry(b, null));

    world.system_registry.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 1 });

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

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addObserverEntry(std.testing.allocator, EventId.from(Damage), buildObserverEntry(onDamage, null));

    world.system_registry.dispatch(std.testing.allocator, &world, EventId.from(Healing), &Healing{ .amount = 5 });

    try std.testing.expectEqual(0, State.damage_calls);
}

test "dispatch: runs nothing when no observer is registered for the event id" {
    const Damage = struct { amount: u32 };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.system_registry.dispatch(std.testing.allocator, &world, EventId.from(Damage), &Damage{ .amount = 1 });
}

test "dispatch: routes on the subject as well as the event" {
    const component = @import("lifecycle.zig").component;
    const ComponentAdded = @import("lifecycle.zig").ComponentAdded;

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

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.system_registry.addObserverEntry(std.testing.allocator, component.added(Position), buildObserverEntry(onPosition, null));
    world.system_registry.addObserverEntry(std.testing.allocator, component.added(Velocity), buildObserverEntry(onVelocity, null));

    const event = ComponentAdded{ .entity = .{ .id = 0, .generation = 0 }, .component = 0 };
    world.system_registry.dispatch(std.testing.allocator, &world, component.added(Position), &event);

    try std.testing.expectEqual(1, State.position_calls);
    try std.testing.expectEqual(0, State.velocity_calls);
}

test "integration: resolves only the parameters a system declares, in any order" {
    const Commands = @import("world.zig").Commands;

    const State = struct {
        var calls: [4]u8 = undefined;
        var count: usize = 0;

        fn record(tag: u8) void {
            calls[count] = tag;
            count += 1;
        }
    };

    const both = struct {
        fn call(_: Commands, _: std.mem.Allocator) void {
            State.record(1);
        }
    }.call;
    const reversed = struct {
        fn call(_: std.mem.Allocator, _: Commands) void {
            State.record(2);
        }
    }.call;
    const commands_only = struct {
        fn call(_: Commands) void {
            State.record(3);
        }
    }.call;
    const nothing = struct {
        fn call() void {
            State.record(4);
        }
    }.call;

    State.count = 0;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(both, null));
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(reversed, null));
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(commands_only, null));
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(nothing, null));

    world.runSystems(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &State.calls);
}

test "integration: accepts any type declaring fromWorld as a system parameter" {
    const Counter = struct {
        world: *World,
        seed: u32,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world, .seed = 42 };
        }
    };

    const State = struct {
        var seed: u32 = 0;
        var world: ?*World = null;
    };
    State.seed = 0;
    State.world = null;

    const system = struct {
        fn call(counter: Counter) void {
            State.seed = counter.seed;
            State.world = counter.world;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(system, null));

    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(42, State.seed);
    try std.testing.expectEqual(&world, State.world);
}

test "integration: runs systems group by group, in registration order" {
    const State = struct {
        var calls: [3]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;
    const c = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 3;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addSystemEntry(std.testing.allocator, 2, buildSystemEntry(a, null));
    world.system_registry.addSystemEntry(std.testing.allocator, 1, buildSystemEntry(b, null));
    world.system_registry.addSystemEntry(std.testing.allocator, 2, buildSystemEntry(c, null));

    world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 2 }, &State.calls);
}

test "integration: runs nothing when no system is registered" {
    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.runSystems(std.testing.allocator);
}

test "integration: runs one shot systems in registration order" {
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addOneShotSystemEntry(std.testing.allocator, buildSystemEntry(a, null));
    world.system_registry.addOneShotSystemEntry(std.testing.allocator, buildSystemEntry(b, null));

    world.runSystems(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "integration: runs a plugin one shot system through its bound plugin" {
    const Plugin = struct {
        calls: usize = 0,

        fn tick(self: *@This(), _: std.mem.Allocator) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    var plugin = Plugin{};
    world.system_registry.addOneShotSystemEntry(std.testing.allocator, buildSystemEntry(Plugin.tick, &plugin));

    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, plugin.calls);
}

test "integration: clears one shot systems so they do not run again" {
    const State = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    world.system_registry.addOneShotSystemEntry(std.testing.allocator, buildSystemEntry(system, null));

    world.runSystems(std.testing.allocator);
    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, State.calls);
    try std.testing.expectEqual(0, world.system_registry.one_shot_systems.items.len);
}
