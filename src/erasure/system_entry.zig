const observer_protocol = @import("../protocols/observer.zig");
const plugin_observer_protocol = @import("../protocols/plugin_observer.zig");
const plugin_system_protocol = @import("../protocols/plugin_system.zig");
const std = @import("std");
const system_protocol = @import("../protocols/system.zig");

const World = @import("../core/world.zig").World;

const resolveObserverParameter = @import("parameter.zig").resolveObserverParameter;
const resolveParameter = @import("parameter.zig").resolveParameter;

const SystemFunction = *const fn (*World, std.mem.Allocator) void;
const ObserverFunction = *const fn (*World, std.mem.Allocator, *const anyopaque) void;

const PluginSystemFunction = *const fn (*anyopaque, std.mem.Allocator, *World) void;
const PluginObserverFunction = *const fn (*anyopaque, std.mem.Allocator, *World, *const anyopaque) void;

pub const SystemEntry = union(enum) {
    function: SystemFunction,
    plugin_function: struct {
        plugin: *anyopaque,
        function: PluginSystemFunction,
    },

    pub fn run(self: SystemEntry, allocator: std.mem.Allocator, world: *World) void {
        switch (self) {
            .function => |function| function(world, allocator),
            .plugin_function => |system| system.function(system.plugin, allocator, world),
        }
    }
};

pub const ObserverEntry = union(enum) {
    function: ObserverFunction,
    plugin_function: struct {
        plugin: *anyopaque,
        function: PluginObserverFunction,
    },

    pub fn run(self: ObserverEntry, allocator: std.mem.Allocator, world: *World, payload: *const anyopaque) void {
        switch (self) {
            .function => |function| function(world, allocator, payload),
            .plugin_function => |observer| observer.function(observer.plugin, allocator, world, payload),
        }
    }
};

pub fn buildSystemEntry(comptime function: anytype, plugin: anytype) SystemEntry {
    if (comptime @TypeOf(plugin) == @TypeOf(null)) {
        if (comptime !system_protocol.validate(@TypeOf(function))) @compileError(
            @typeName(@TypeOf(function)) ++ " does not implement the System protocol",
        );
        return .{ .function = systemInvoker(function) };
    } else {
        const Plugin = PluginType(@TypeOf(plugin), "system");
        if (comptime !plugin_system_protocol.validate(@TypeOf(function), Plugin)) @compileError(
            @typeName(@TypeOf(function)) ++ " does not implement the PluginSystem protocol",
        );
        const typed_plugin: *Plugin = plugin;
        return .{ .plugin_function = .{
            .plugin = typed_plugin,
            .function = pluginSystemInvoker(function),
        } };
    }
}

pub fn buildObserverEntry(comptime function: anytype, plugin: anytype) ObserverEntry {
    if (comptime @TypeOf(plugin) == @TypeOf(null)) {
        if (comptime !observer_protocol.validate(@TypeOf(function))) @compileError(
            @typeName(@TypeOf(function)) ++ " does not implement the Observer protocol",
        );
        return .{ .function = observerInvoker(function) };
    } else {
        const Plugin = PluginType(@TypeOf(plugin), "observer");
        if (comptime !plugin_observer_protocol.validate(@TypeOf(function), Plugin)) @compileError(
            @typeName(@TypeOf(function)) ++ " does not implement the PluginObserver protocol",
        );
        const typed_plugin: *Plugin = plugin;
        return .{ .plugin_function = .{
            .plugin = typed_plugin,
            .function = pluginObserverInvoker(function),
        } };
    }
}

fn systemInvoker(comptime function: anytype) SystemFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator) void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            resolveArguments(@TypeOf(function), 0, &arguments, allocator, world);
            @call(.auto, function, arguments);
        }
    }.call;
}

fn pluginSystemInvoker(comptime function: anytype) PluginSystemFunction {
    return struct {
        fn call(plugin: *anyopaque, allocator: std.mem.Allocator, world: *World) void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            arguments[0] = @ptrCast(@alignCast(plugin));
            resolveArguments(@TypeOf(function), 1, &arguments, allocator, world);
            @call(.auto, function, arguments);
        }
    }.call;
}

fn observerInvoker(comptime function: anytype) ObserverFunction {
    return struct {
        fn call(world: *World, allocator: std.mem.Allocator, payload: *const anyopaque) void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            resolveObserverArguments(@TypeOf(function), 0, &arguments, allocator, world, payload);
            @call(.auto, function, arguments);
        }
    }.call;
}

fn pluginObserverInvoker(comptime function: anytype) PluginObserverFunction {
    return struct {
        fn call(plugin: *anyopaque, allocator: std.mem.Allocator, world: *World, payload: *const anyopaque) void {
            var arguments: std.meta.ArgsTuple(@TypeOf(function)) = undefined;
            arguments[0] = @ptrCast(@alignCast(plugin));
            resolveObserverArguments(@TypeOf(function), 1, &arguments, allocator, world, payload);
            @call(.auto, function, arguments);
        }
    }.call;
}

fn resolveArguments(
    comptime Function: type,
    comptime skip: usize,
    arguments: *std.meta.ArgsTuple(Function),
    allocator: std.mem.Allocator,
    world: *World,
) void {
    inline for (arguments, 0..) |*argument, index| {
        if (comptime index < skip) continue;
        argument.* = resolveParameter(allocator, world, @TypeOf(argument.*));
    }
}

fn resolveObserverArguments(
    comptime Function: type,
    comptime skip: usize,
    arguments: *std.meta.ArgsTuple(Function),
    allocator: std.mem.Allocator,
    world: *World,
    payload: *const anyopaque,
) void {
    inline for (arguments, 0..) |*argument, index| {
        if (comptime index < skip) continue;
        argument.* = resolveObserverParameter(allocator, world, @TypeOf(argument.*), payload);
    }
}

fn PluginType(comptime Pointer: type, comptime kind: []const u8) type {
    const error_message = "a plugin " ++ kind ++ " must be given a mutable single-item pointer to its plugin";

    const pointer = switch (@typeInfo(Pointer)) {
        .pointer => |info| info,
        else => @compileError(error_message),
    };
    if (pointer.size != .one or pointer.is_const) @compileError(error_message);

    return pointer.child;
}

test "SystemEntry.run: calls a plain function entry" {
    const TestState = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call(_: std.mem.Allocator) void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildSystemEntry(system, null).run(std.testing.allocator, &world);

    try std.testing.expectEqual(1, TestState.calls);
}

test "SystemEntry.run: calls a plugin entry through the bound plugin" {
    const Plugin = struct {
        total: u32 = 0,

        fn update(self: *@This()) void {
            self.total += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var plugin = Plugin{};
    const entry = buildSystemEntry(Plugin.update, &plugin);

    entry.run(std.testing.allocator, &world);
    entry.run(std.testing.allocator, &world);

    try std.testing.expectEqual(2, plugin.total);
}

test "ObserverEntry.run: hands the payload to a plain function entry" {
    const Event = @import("../params/views/event.zig").Event;

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

    const damage = Damage{ .amount = 7 };
    buildObserverEntry(observer, null).run(std.testing.allocator, &world, &damage);

    try std.testing.expectEqual(7, TestState.seen);
}

test "ObserverEntry.run: hands the payload to a plugin entry" {
    const Event = @import("../params/views/event.zig").Event;

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
    const entry = buildObserverEntry(Plugin.onDamage, &plugin);

    entry.run(std.testing.allocator, &world, &Damage{ .amount = 3 });
    entry.run(std.testing.allocator, &world, &Damage{ .amount = 4 });

    try std.testing.expectEqual(7, plugin.total);
}

test "buildSystemEntry: builds a function entry when no plugin is given" {
    const system = struct {
        fn call(_: std.mem.Allocator) void {}
    }.call;

    try std.testing.expectEqual(.function, std.meta.activeTag(buildSystemEntry(system, null)));
}

test "buildSystemEntry: binds the plugin pointer it was given" {
    const Plugin = struct {
        value: u32 = 0,

        fn update(_: *@This()) void {}
    };

    var plugin = Plugin{};
    const entry = buildSystemEntry(Plugin.update, &plugin);

    try std.testing.expectEqual(.plugin_function, std.meta.activeTag(entry));
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&plugin)),
        entry.plugin_function.plugin,
    );
}

test "buildSystemEntry: resolves the parameters the system declares" {
    const TestState = struct {
        var seen_allocator: ?std.mem.Allocator = null;
    };
    const system = struct {
        fn call(allocator: std.mem.Allocator) void {
            TestState.seen_allocator = allocator;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildSystemEntry(system, null).run(std.testing.allocator, &world);

    try std.testing.expect(TestState.seen_allocator != null);
}

test "buildSystemEntry: runs a system that declares no parameters" {
    const TestState = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call() void {
            TestState.calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildSystemEntry(system, null).run(std.testing.allocator, &world);

    try std.testing.expectEqual(1, TestState.calls);
}

test "buildSystemEntry: gives a plugin system its receiver before other parameters" {
    const Plugin = struct {
        ready: bool = true,

        var saw_receiver: bool = false;

        fn update(self: *@This(), _: std.mem.Allocator) void {
            saw_receiver = self.ready;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var plugin = Plugin{};
    buildSystemEntry(Plugin.update, &plugin).run(std.testing.allocator, &world);

    try std.testing.expect(Plugin.saw_receiver);
}

test "buildObserverEntry: builds a function entry when no plugin is given" {
    const Event = @import("../params/views/event.zig").Event;

    const Damage = struct { amount: u32 };
    const observer = struct {
        fn call(_: Event(Damage)) void {}
    }.call;

    try std.testing.expectEqual(.function, std.meta.activeTag(buildObserverEntry(observer, null)));
}

test "buildObserverEntry: binds the plugin pointer it was given" {
    const Event = @import("../params/views/event.zig").Event;

    const Damage = struct { amount: u32 };
    const Plugin = struct {
        value: u32 = 0,

        fn onDamage(_: *@This(), _: Event(Damage)) void {}
    };

    var plugin = Plugin{};
    const entry = buildObserverEntry(Plugin.onDamage, &plugin);

    try std.testing.expectEqual(.plugin_function, std.meta.activeTag(entry));
    try std.testing.expectEqual(
        @as(*anyopaque, @ptrCast(&plugin)),
        entry.plugin_function.plugin,
    );
}

test "buildObserverEntry: resolves parameters beyond the event" {
    const Event = @import("../params/views/event.zig").Event;

    const Damage = struct { amount: u32 };
    const TestState = struct {
        var seen_amount: u32 = 0;
        var seen_allocator: bool = false;
    };
    const observer = struct {
        fn call(allocator: std.mem.Allocator, event: Event(Damage)) void {
            _ = allocator;
            TestState.seen_allocator = true;
            TestState.seen_amount = event.value.amount;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildObserverEntry(observer, null).run(std.testing.allocator, &world, &Damage{ .amount = 5 });

    try std.testing.expect(TestState.seen_allocator);
    try std.testing.expectEqual(5, TestState.seen_amount);
}
