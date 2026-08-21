const std = @import("std");
const util = @import("../utils.zig");

const DeinitFunction = @import("../erasure/deinit.zig").DeinitFunction;
const DestroyFunction = @import("../erasure/deinit.zig").DestroyFunction;
const World = @import("../core/world.zig").World;

const getDeinitFunction = @import("../erasure/deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("../erasure/deinit.zig").getDestroyFunction;
const resolveParameter = @import("../erasure/parameter.zig").resolveParameter;

pub const Plugins = struct {
    pub const State = PluginsState;

    state: *State,
    world: *World,

    pub fn fromWorld(_: std.mem.Allocator, world: *World) Plugins {
        return .{ .state = &world.plugins, .world = world };
    }
};

const PluginsState = struct {
    plugins: std.ArrayList(PluginEntry) = .empty,

    pub fn init() PluginsState {
        return .{};
    }

    pub fn deinit(self: *PluginsState, allocator: std.mem.Allocator) void {
        var entries = std.mem.reverseIterator(self.plugins.items);
        while (entries.next()) |entry| {
            entry.deinit(allocator, entry.plugin);
            entry.destroy(allocator, entry.plugin);
        }
        self.plugins.deinit(allocator);
    }

    pub fn addPlugin(
        self: *PluginsState,
        allocator: std.mem.Allocator,
        world: *World,
        plugin: anytype,
    ) void {
        const T = @TypeOf(plugin);
        const name = @typeName(T);
        const build_error_message = name ++ ".build must take *" ++ name ++
            " as its first parameter and return void";

        comptime {
            if (@typeInfo(T) != .@"struct") {
                @compileError("a plugin must be a struct value, got " ++ name);
            }

            if (!std.meta.hasFn(T, "build")) @compileError(name ++ " must declare build");
            const build_info = @typeInfo(@TypeOf(T.build)).@"fn";
            if (build_info.params.len == 0 or build_info.params[0].type != *T) {
                @compileError(build_error_message);
            }
            if (build_info.return_type != void) @compileError(build_error_message);
        }

        const stored = allocator.create(T) catch util.panicOom("PluginsState.addPlugin");
        stored.* = plugin;

        self.plugins.append(allocator, .{
            .plugin = stored,
            .deinit = getDeinitFunction(T),
            .destroy = getDestroyFunction(T),
        }) catch util.panicOom("PluginsState.addPlugin");

        var arguments: std.meta.ArgsTuple(@TypeOf(T.build)) = undefined;
        inline for (&arguments, 0..) |*argument, index| {
            if (comptime index == 0) {
                argument.* = stored;
            } else {
                argument.* = resolveParameter(allocator, world, @TypeOf(argument.*));
            }
        }

        @call(.auto, T.build, arguments);
    }
};

const PluginEntry = struct {
    plugin: *anyopaque,
    deinit: DeinitFunction,
    destroy: DestroyFunction,
};

test "deinit: calls a plugin deinit that takes an allocator" {
    const allocator = std.testing.allocator;

    const Plugin = struct {
        buffer: []u8,

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.buffer);
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var registry = PluginsState.init();
    registry.addPlugin(allocator, &world, Plugin{
        .buffer = allocator.alloc(u8, 8) catch util.panicOom("test"),
    });
    registry.deinit(allocator);
}

test "deinit: destroys plugins in reverse registration order" {
    const TestState = struct {
        var order: [2]u8 = undefined;
        var count: usize = 0;

        fn record(tag: u8) void {
            order[count] = tag;
            count += 1;
        }
    };
    const First = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(_: *@This()) void {
            TestState.record('a');
        }
    };
    const Second = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(_: *@This()) void {
            TestState.record('b');
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    registry.addPlugin(std.testing.allocator, &world, First{});
    registry.addPlugin(std.testing.allocator, &world, Second{});
    registry.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "ba", &TestState.order);
}

test "deinit: calls a plugin deinit that takes no allocator" {
    const TestState = struct {
        var count: usize = 0;
    };
    const Plugin = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(_: *@This()) void {
            TestState.count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();

    registry.addPlugin(std.testing.allocator, &world, Plugin{});
    registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, TestState.count);
}

test "addPlugin: stores the plugin the caller passed" {
    const Plugin = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{});

    try std.testing.expectEqual(1, registry.plugins.items.len);
}

test "addPlugin: keeps the field values the caller set" {
    const Plugin = struct {
        scale: f32 = 1,
        label: []const u8 = "default",

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{ .scale = 2.5, .label = "configured" });

    const stored: *Plugin = @ptrCast(@alignCast(registry.plugins.items[0].plugin));
    try std.testing.expectEqual(@as(f32, 2.5), stored.scale);
    try std.testing.expectEqualStrings("configured", stored.label);
}

test "addPlugin: keeps a value the caller built with an allocator" {
    const Plugin = struct {
        ready: bool,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{ .ready = true };
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin.init(std.testing.allocator));

    const stored: *Plugin = @ptrCast(@alignCast(registry.plugins.items[0].plugin));
    try std.testing.expect(stored.ready);
}

test "addPlugin: calls a build that takes only the plugin" {
    const TestState = struct {
        var built: bool = false;
    };
    const Plugin = struct {
        ready: bool = true,

        pub fn build(self: *@This()) void {
            TestState.built = self.ready;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{});

    try std.testing.expect(TestState.built);
}

test "addPlugin: resolves a query parameter for build" {
    const Query = @import("../params/views/query.zig").Query;

    const TestState = struct {
        var ran: bool = false;
    };

    const Position = struct { x: f32, y: f32 };

    const Plugin = struct {
        pub fn build(_: *@This(), positions: Query(&.{Position})) void {
            var it = positions.iterator();
            TestState.ran = it.next() == null;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{});

    try std.testing.expect(TestState.ran);
}

test "addPlugin: resolves a resource parameter for build" {
    const Resource = @import("../params/views/resource.zig").Resource;

    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };
    const TestState = struct {
        var scale: f32 = 0;
    };

    const Plugin = struct {
        pub fn build(_: *@This(), config: Resource(Config)) void {
            TestState.scale = config.value.scale;
        }
    };

    var world = World.init(allocator);
    defer world.deinit(allocator);

    world.resources.addOwned(&world, allocator, Config, .{ .scale = 2.5 });

    var registry = PluginsState.init();
    defer registry.deinit(allocator);

    registry.addPlugin(allocator, &world, Plugin{});

    try std.testing.expectEqual(@as(f32, 2.5), TestState.scale);
}

test "addPlugin: passes the caller's plugin value to build" {
    const TestState = struct {
        var seen_scale: f32 = 0;
    };
    const Plugin = struct {
        scale: f32,

        pub fn build(self: *@This(), _: std.mem.Allocator) void {
            TestState.seen_scale = self.scale;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{ .scale = 2.5 });

    try std.testing.expectEqual(@as(f32, 2.5), TestState.seen_scale);
}

test "addPlugin: resolves a parameter declaring fromWorld for build" {
    const WorldRef = struct {
        world: *World,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world };
        }
    };

    const TestState = struct {
        var seen: ?*World = null;
    };
    const Plugin = struct {
        pub fn build(_: *@This(), world: WorldRef) void {
            TestState.seen = world.world;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{});

    try std.testing.expectEqual(&world, TestState.seen.?);
}

test "addPlugin: stores a plugin that declares no deinit" {
    const Plugin = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{});

    try std.testing.expectEqual(1, registry.plugins.items.len);
}

test "addPlugin: adds the same plugin type more than once" {
    const TestState = struct {
        var build_count: usize = 0;
    };
    const Plugin = struct {
        tag: u8,

        pub fn build(_: *@This(), _: std.mem.Allocator) void {
            TestState.build_count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    var registry = PluginsState.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin{ .tag = 'a' });
    registry.addPlugin(std.testing.allocator, &world, Plugin{ .tag = 'b' });

    try std.testing.expectEqual(2, TestState.build_count);
    try std.testing.expectEqual(2, registry.plugins.items.len);

    const first: *Plugin = @ptrCast(@alignCast(registry.plugins.items[0].plugin));
    const second: *Plugin = @ptrCast(@alignCast(registry.plugins.items[1].plugin));
    try std.testing.expectEqual(@as(u8, 'a'), first.tag);
    try std.testing.expectEqual(@as(u8, 'b'), second.tag);
}
