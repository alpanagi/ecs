const std = @import("std");

const World = @import("../core/world.zig").World;
const Event = @import("../params/views/event.zig").Event;
const resolveParameter = @import("parameter.zig").resolveParameter;
const resolveObserverParameter = @import("parameter.zig").resolveObserverParameter;

pub const SystemFunction = *const fn (*World, std.mem.Allocator) void;
pub const ObserverFunction = *const fn (*World, std.mem.Allocator, *const anyopaque) void;

pub const PluginSystemFunction = *const fn (*anyopaque, std.mem.Allocator, *World) void;
pub const PluginObserverFunction = *const fn (*anyopaque, std.mem.Allocator, *World, *const anyopaque) void;

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
    validateReturnsVoid(@TypeOf(function), "system");

    if (comptime @TypeOf(plugin) == @TypeOf(null)) {
        return .{ .function = systemInvoker(function) };
    } else {
        const Plugin = pluginType(@TypeOf(plugin), "system");
        validatePluginReceiver(Plugin, @TypeOf(function), "system");
        const typed_plugin: *Plugin = plugin;
        return .{ .plugin_function = .{
            .plugin = typed_plugin,
            .function = pluginSystemInvoker(function),
        } };
    }
}

pub fn buildObserverEntry(comptime function: anytype, plugin: anytype) ObserverEntry {
    validateReturnsVoid(@TypeOf(function), "observer");

    if (comptime @TypeOf(plugin) == @TypeOf(null)) {
        return .{ .function = observerInvoker(function) };
    } else {
        const Plugin = pluginType(@TypeOf(plugin), "observer");
        validatePluginReceiver(Plugin, @TypeOf(function), "observer");
        const typed_plugin: *Plugin = plugin;
        return .{ .plugin_function = .{
            .plugin = typed_plugin,
            .function = pluginObserverInvoker(function),
        } };
    }
}

fn validateReturnsVoid(comptime Function: type, comptime kind: []const u8) void {
    if (functionInfo(Function, kind).return_type != void) {
        @compileError(kind ++ " must return void");
    }
}

fn validatePluginReceiver(comptime Plugin: type, comptime Function: type, comptime kind: []const u8) void {
    const error_message = "a plugin " ++ kind ++ " must take *" ++ @typeName(Plugin) ++ " as its first parameter";

    const info = functionInfo(Function, kind);
    if (info.params.len == 0) @compileError(error_message);

    const Receiver = info.params[0].type orelse @compileError(error_message);
    if (Receiver != *Plugin) @compileError(error_message);
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

fn pluginType(comptime Pointer: type, comptime kind: []const u8) type {
    const error_message = "a plugin " ++ kind ++ " must be given a mutable single-item pointer to its plugin";

    const pointer = switch (@typeInfo(Pointer)) {
        .pointer => |info| info,
        else => @compileError(error_message),
    };
    if (pointer.size != .one or pointer.is_const) @compileError(error_message);

    return pointer.child;
}

fn functionInfo(comptime F: type, comptime kind: []const u8) std.builtin.Type.Fn {
    return switch (@typeInfo(F)) {
        .@"fn" => |info| info,
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .@"fn" => |info| info,
            else => @compileError(kind ++ " must be a function"),
        },
        else => @compileError(kind ++ " must be a function"),
    };
}

test "SystemEntry.run: calls a plain function entry" {
    const State = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call(_: std.mem.Allocator) void {
            State.calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildSystemEntry(system, null).run(std.testing.allocator, &world);

    try std.testing.expectEqual(1, State.calls);
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

    const damage = Damage{ .amount = 7 };
    buildObserverEntry(observer, null).run(std.testing.allocator, &world, &damage);

    try std.testing.expectEqual(7, State.seen);
}

test "ObserverEntry.run: hands the payload to a plugin entry" {
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
    const State = struct {
        var seen_allocator: ?std.mem.Allocator = null;
    };
    const system = struct {
        fn call(allocator: std.mem.Allocator) void {
            State.seen_allocator = allocator;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildSystemEntry(system, null).run(std.testing.allocator, &world);

    try std.testing.expect(State.seen_allocator != null);
}

test "buildSystemEntry: runs a system that declares no parameters" {
    const State = struct {
        var calls: usize = 0;
    };
    const system = struct {
        fn call() void {
            State.calls += 1;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildSystemEntry(system, null).run(std.testing.allocator, &world);

    try std.testing.expectEqual(1, State.calls);
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
    const Damage = struct { amount: u32 };
    const observer = struct {
        fn call(_: Event(Damage)) void {}
    }.call;

    try std.testing.expectEqual(.function, std.meta.activeTag(buildObserverEntry(observer, null)));
}

test "buildObserverEntry: binds the plugin pointer it was given" {
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
    const Damage = struct { amount: u32 };
    const State = struct {
        var seen_amount: u32 = 0;
        var seen_allocator: bool = false;
    };
    const observer = struct {
        fn call(allocator: std.mem.Allocator, event: Event(Damage)) void {
            _ = allocator;
            State.seen_allocator = true;
            State.seen_amount = event.value.amount;
        }
    }.call;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    buildObserverEntry(observer, null).run(std.testing.allocator, &world, &Damage{ .amount = 5 });

    try std.testing.expect(State.seen_allocator);
    try std.testing.expectEqual(5, State.seen_amount);
}
