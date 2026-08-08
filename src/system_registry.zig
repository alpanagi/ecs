const std = @import("std");

const World = @import("world.zig").World;
const hash = @import("hash.zig").hash;
const resolveParameter = @import("parameter.zig").resolveParameter;
const resolveObserverParameter = @import("parameter.zig").resolveObserverParameter;

pub const SystemFunction = *const fn (*World, std.mem.Allocator) anyerror!void;
pub const ObserverFunction = *const fn (*World, std.mem.Allocator, *const anyopaque) anyerror!void;

pub const PluginSystemFunction = *const fn (*anyopaque, std.mem.Allocator, *World) anyerror!void;
pub const PluginObserverFunction = *const fn (*anyopaque, std.mem.Allocator, *World, *const anyopaque) anyerror!void;

pub const SystemEntry = union(enum) {
    function: SystemFunction,
    plugin_function: struct {
        plugin: *anyopaque,
        function: PluginSystemFunction,
    },

    pub fn run(self: SystemEntry, allocator: std.mem.Allocator, world: *World) !void {
        switch (self) {
            .function => |function| try function(world, allocator),
            .plugin_function => |system| try system.function(system.plugin, allocator, world),
        }
    }
};

pub const ObserverEntry = union(enum) {
    function: ObserverFunction,
    plugin_function: struct {
        plugin: *anyopaque,
        function: PluginObserverFunction,
    },

    pub fn run(self: ObserverEntry, allocator: std.mem.Allocator, world: *World, event: *const anyopaque) !void {
        switch (self) {
            .function => |function| try function(world, allocator, event),
            .plugin_function => |observer| try observer.function(observer.plugin, allocator, world, event),
        }
    }
};

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
    observers: std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(ObserverEntry)) = .{},
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

    pub fn registerSystem(
        self: *SystemRegistry,
        allocator: std.mem.Allocator,
        group: u64,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        const entry = buildSystemEntry(function, plugin);
        try appendEntry(SystemEntry, &self.groups, allocator, group, entry);
    }

    pub fn registerOneShotSystem(
        self: *SystemRegistry,
        allocator: std.mem.Allocator,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        const entry = buildSystemEntry(function, plugin);
        try self.one_shot_systems.append(allocator, entry);
    }

    pub fn runOneShotSystems(self: *SystemRegistry, allocator: std.mem.Allocator, world: *World) void {
        for (self.one_shot_systems.items) |entry| {
            entry.run(allocator, world) catch |err| std.log.err("system failed: {}\n", .{err});
        }
        self.one_shot_systems.clearRetainingCapacity();
    }

    pub fn groupIterator(self: *const SystemRegistry) GroupIterator {
        return .{ .groups = self.groups.values() };
    }

    pub fn registerObserver(
        self: *SystemRegistry,
        allocator: std.mem.Allocator,
        comptime function: anytype,
        plugin: anytype,
    ) !void {
        var entry: ObserverEntry = undefined;
        var event: u64 = undefined;

        if (comptime @TypeOf(plugin) == @TypeOf(null)) {
            event = hash(eventPayload(@TypeOf(function), 0));
            entry = .{ .function = observerInvoker(function) };
        } else {
            const Plugin = pluginType(@TypeOf(plugin));
            validatePluginReceiver(Plugin, @TypeOf(function), "observer");
            event = hash(eventPayload(@TypeOf(function), 1));
            const typed_plugin: *Plugin = plugin;
            entry = .{ .plugin_function = .{
                .plugin = typed_plugin,
                .function = pluginObserverInvoker(Plugin, function),
            } };
        }

        try appendEntry(ObserverEntry, &self.observers, allocator, event, entry);
    }

    pub fn dispatch(
        self: *SystemRegistry,
        allocator: std.mem.Allocator,
        event: u64,
        world: *World,
        payload: *const anyopaque,
    ) void {
        if (self.observers.get(event)) |entries| {
            for (entries.items) |entry| {
                entry.run(allocator, world, payload) catch |err| std.log.err("observer failed: {}\n", .{err});
            }
        }
    }
};

fn appendEntry(
    comptime Entry: type,
    map: *std.AutoArrayHashMapUnmanaged(u64, std.ArrayList(Entry)),
    allocator: std.mem.Allocator,
    key: u64,
    entry: Entry,
) !void {
    const gop = try map.getOrPut(allocator, key);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    gop.value_ptr.append(allocator, entry) catch |err| {
        if (!gop.found_existing) {
            gop.value_ptr.deinit(allocator);
            _ = map.orderedRemove(key);
        }
        return err;
    };
}

fn buildSystemEntry(comptime function: anytype, plugin: anytype) SystemEntry {
    if (comptime @TypeOf(plugin) == @TypeOf(null)) {
        return .{ .function = systemInvoker(function) };
    } else {
        const Plugin = pluginType(@TypeOf(plugin));
        validatePluginReceiver(Plugin, @TypeOf(function), "system");
        const typed_plugin: *Plugin = plugin;
        return .{ .plugin_function = .{
            .plugin = typed_plugin,
            .function = pluginInvoker(Plugin, function),
        } };
    }
}

fn pluginType(comptime Pointer: type) type {
    const pointer = switch (@typeInfo(Pointer)) {
        .pointer => |info| info,
        else => @compileError("plugin must be a pointer"),
    };
    if (pointer.size != .one or pointer.is_const) {
        @compileError("plugin must be a mutable single-item pointer");
    }
    return pointer.child;
}

fn validatePluginReceiver(comptime Plugin: type, comptime Function: type, comptime kind: []const u8) void {
    const info = functionInfo(Function);
    if (info.params.len == 0 or info.params[0].type.? != *Plugin) {
        @compileError("a plugin " ++ kind ++ " must take *" ++ @typeName(Plugin) ++ " as its first parameter");
    }
}

pub fn Event(comptime T: type) type {
    return struct {
        value: *const T,

        pub const Payload = T;

        pub fn fromEvent(payload: *const anyopaque) @This() {
            return .{ .value = @ptrCast(@alignCast(payload)) };
        }
    };
}

fn eventPayload(comptime Function: type, comptime skipped: usize) type {
    const info = functionInfo(Function);
    comptime var found: ?type = null;
    inline for (info.params, 0..) |param, index| {
        if (index < skipped) continue;
        const Parameter = param.type.?;
        if (comptime std.meta.hasFn(Parameter, "fromEvent")) {
            if (found != null) @compileError("an observer must declare exactly one Event parameter");
            found = Parameter.Payload;
        }
    }
    return found orelse @compileError(
        "an observer must declare exactly one Event parameter, " ++
            @typeName(Function) ++ " declares none",
    );
}

fn functionInfo(comptime F: type) std.builtin.Type.Fn {
    return switch (@typeInfo(F)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError("system must be a function"),
        },
        else => @compileError("system must be a function"),
    };
}

fn systemInvoker(comptime function: anytype) SystemFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator) anyerror!void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            inline for (&arguments) |*argument| argument.* = resolveParameter(@TypeOf(argument.*), allocator, world);
            return @call(.auto, function, arguments);
        }
    }.call;
}

fn pluginInvoker(comptime T: type, comptime function: anytype) PluginSystemFunction {
    return struct {
        fn call(plugin: *anyopaque, allocator: std.mem.Allocator, world: *World) anyerror!void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            inline for (&arguments, 0..) |*argument, index| {
                if (comptime index == 0) {
                    const typed_plugin: *T = @ptrCast(@alignCast(plugin));
                    argument.* = typed_plugin;
                } else {
                    argument.* = resolveParameter(@TypeOf(argument.*), allocator, world);
                }
            }
            return @call(.auto, function, arguments);
        }
    }.call;
}

fn pluginObserverInvoker(comptime T: type, comptime function: anytype) PluginObserverFunction {
    return struct {
        fn call(plugin: *anyopaque, allocator: std.mem.Allocator, world: *World, payload: *const anyopaque) anyerror!void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            inline for (&arguments, 0..) |*argument, index| {
                if (comptime index == 0) {
                    const typed_plugin: *T = @ptrCast(@alignCast(plugin));
                    argument.* = typed_plugin;
                } else {
                    argument.* = resolveObserverParameter(@TypeOf(argument.*), allocator, world, payload);
                }
            }
            return @call(.auto, function, arguments);
        }
    }.call;
}

fn observerInvoker(comptime function: anytype) ObserverFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator, payload: *const anyopaque) anyerror!void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            inline for (&arguments) |*argument| {
                argument.* = resolveObserverParameter(@TypeOf(argument.*), allocator, world, payload);
            }
            return @call(.auto, function, arguments);
        }
    }.call;
}

test "a system may declare only the parameters it needs, in any order" {
    const State = struct {
        var calls: [4]u8 = undefined;
        var count: usize = 0;

        fn record(tag: u8) void {
            calls[count] = tag;
            count += 1;
        }
    };

    const both = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.record(1);
        }
    }.call;
    const reversed = struct {
        fn call(_: std.mem.Allocator, _: *World) !void {
            State.record(2);
        }
    }.call;
    const world_only = struct {
        fn call(_: *World) !void {
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
    try world.system_registry.registerSystem(std.testing.allocator, 1, both, null);
    try world.system_registry.registerSystem(std.testing.allocator, 1, reversed, null);
    try world.system_registry.registerSystem(std.testing.allocator, 1, world_only, null);
    try world.system_registry.registerSystem(std.testing.allocator, 1, nothing, null);

    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &State.calls);
}

test "any type declaring fromWorld can be a system parameter" {
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
    try world.system_registry.registerSystem(std.testing.allocator, 1, system, null);

    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(42, State.seed);
    try std.testing.expectEqual(&world, State.world);
}

test "a system receives the world it was run against" {
    const State = struct {
        var seen: ?*World = null;
    };
    const system = struct {
        fn call(world: *World) void {
            State.seen = world;
        }
    }.call;

    State.seen = null;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerSystem(std.testing.allocator, 1, system, null);

    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(&world, State.seen);
}

test "registerSystem creates a group on first use" {
    const system = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call;

    var registry = SystemRegistry.init();
    defer registry.deinit(std.testing.allocator);
    try registry.registerSystem(std.testing.allocator, 1, system, null);

    try std.testing.expectEqual(1, registry.groups.count());
    try std.testing.expectEqual(1, registry.groups.get(1).?.items.len);
}

test "registerSystem appends to an existing group in call order" {
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerSystem(std.testing.allocator, 1, a, null);
    try world.system_registry.registerSystem(std.testing.allocator, 1, b, null);

    try world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "registerSystem binds the plugin pointer when provided" {
    const Plugin = struct {
        calls: usize = 0,

        fn update(self: *@This(), _: std.mem.Allocator, _: *World) void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    var plugin = Plugin{};
    try world.system_registry.registerSystem(std.testing.allocator, 1, Plugin.update, &plugin);

    try world.runSystems(std.testing.allocator);
    try std.testing.expectEqual(1, plugin.calls);
}

test "registerSystem preserves group order by first registration" {
    const a = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {}
    }.call;
    const b = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {}
    }.call;

    var registry = SystemRegistry.init();
    defer registry.deinit(std.testing.allocator);
    try registry.registerSystem(std.testing.allocator, 2, a, null);
    try registry.registerSystem(std.testing.allocator, 1, b, null);
    try registry.registerSystem(std.testing.allocator, 2, b, null);

    try std.testing.expectEqualSlices(u64, &.{ 2, 1 }, registry.groups.keys());
}

test "runSystems runs systems group by group, in registration order" {
    const State = struct {
        var calls: [3]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;
    const c = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 3;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerSystem(std.testing.allocator, 2, a, null);
    try world.system_registry.registerSystem(std.testing.allocator, 1, b, null);
    try world.system_registry.registerSystem(std.testing.allocator, 2, c, null);

    try world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 2 }, &State.calls);
}

test "runSystems is a no-op when nothing is registered" {
    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.runSystems(std.testing.allocator);
}

test "dispatch runs a registered observer with the triggered event's data" {
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
    try world.system_registry.registerObserver(std.testing.allocator, observer, null);

    const damage = Damage{ .amount = 10 };
    world.system_registry.dispatch(std.testing.allocator, hash(Damage), &world, &damage);

    try std.testing.expectEqual(10, State.seen);
}

test "dispatch binds the plugin pointer when provided" {
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
    try world.system_registry.registerObserver(std.testing.allocator, Plugin.onDamage, &plugin);

    world.system_registry.dispatch(std.testing.allocator, hash(Damage), &world, &Damage{ .amount = 3 });
    world.system_registry.dispatch(std.testing.allocator, hash(Damage), &world, &Damage{ .amount = 4 });

    try std.testing.expectEqual(7, plugin.total);
}

test "dispatch runs observers for the same event type in registration order" {
    const Damage = struct { amount: u32 };
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: Event(Damage)) !void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: Event(Damage)) !void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerObserver(std.testing.allocator, a, null);
    try world.system_registry.registerObserver(std.testing.allocator, b, null);

    world.system_registry.dispatch(std.testing.allocator, hash(Damage), &world, &Damage{ .amount = 1 });

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "dispatch does not run observers registered for a different event type" {
    const Damage = struct { amount: u32 };
    const Healing = struct { amount: u32 };
    const State = struct {
        var damage_calls: usize = 0;
    };
    const onDamage = struct {
        fn call(_: Event(Damage)) !void {
            State.damage_calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerObserver(std.testing.allocator, onDamage, null);

    world.system_registry.dispatch(std.testing.allocator, hash(Healing), &world, &Healing{ .amount = 5 });

    try std.testing.expectEqual(0, State.damage_calls);
}

test "dispatch is a no-op when nothing is registered for the event" {
    const Damage = struct { amount: u32 };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    world.system_registry.dispatch(std.testing.allocator, hash(Damage), &world, &Damage{ .amount = 1 });
}

test "registerOneShotSystem appends to one_shot_systems" {
    const system = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {}
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerOneShotSystem(std.testing.allocator, system, null);

    try std.testing.expectEqual(1, world.system_registry.one_shot_systems.items.len);
}

test "runSystems runs registered one-shot systems in registration order" {
    const State = struct {
        var calls: [2]u8 = undefined;
        var count: usize = 0;
    };
    const a = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 1;
            State.count += 1;
        }
    }.call;
    const b = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls[State.count] = 2;
            State.count += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerOneShotSystem(std.testing.allocator, a, null);
    try world.system_registry.registerOneShotSystem(std.testing.allocator, b, null);

    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, &State.calls);
}

test "runSystems binds the plugin pointer for a one-shot system when provided" {
    const Plugin = struct {
        calls: usize = 0,

        fn tick(self: *@This(), _: std.mem.Allocator, _: *World) !void {
            self.calls += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    var plugin = Plugin{};
    try world.system_registry.registerOneShotSystem(std.testing.allocator, Plugin.tick, &plugin);

    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, plugin.calls);
}

test "runSystems clears one-shot systems so they do not run again" {
    const State = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call(_: *World, _: std.mem.Allocator) !void {
            State.calls += 1;
        }
    }.call;

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.system_registry.registerOneShotSystem(std.testing.allocator, system, null);

    try world.runSystems(std.testing.allocator);
    try world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(1, State.calls);
    try std.testing.expectEqual(0, world.system_registry.one_shot_systems.items.len);
}
