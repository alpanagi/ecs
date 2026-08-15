const std = @import("std");

const util = @import("util.zig");
const World = @import("world.zig").World;
const DeinitFunction = @import("deinit.zig").DeinitFunction;
const DestroyFunction = @import("deinit.zig").DestroyFunction;
const getDeinitFunction = @import("deinit.zig").getDeinitFunction;
const getDestroyFunction = @import("deinit.zig").getDestroyFunction;
const resolveParameter = @import("parameter.zig").resolveParameter;
const Resource = @import("resource.zig").Resource;

const PluginEntry = struct {
    plugin: *anyopaque,
    deinit: DeinitFunction,
    destroy: DestroyFunction,
};

pub const PluginRegistry = struct {
    plugins: std.ArrayList(PluginEntry) = .empty,

    pub fn init() PluginRegistry {
        return .{};
    }

    pub fn deinit(self: *PluginRegistry, allocator: std.mem.Allocator) void {
        var entries = std.mem.reverseIterator(self.plugins.items);
        while (entries.next()) |entry| {
            entry.deinit(allocator, entry.plugin);
            entry.destroy(allocator, entry.plugin);
        }
        self.plugins.deinit(allocator);
    }

    pub fn addPlugin(
        self: *PluginRegistry,
        allocator: std.mem.Allocator,
        world: *World,
        comptime T: type,
    ) void {
        const name = @typeName(T);
        const init_error_message = name ++ ".init has an unsupported signature, expected fn () " ++
            name ++ " or fn (std.mem.Allocator) " ++ name;
        const build_error_message = name ++ ".build must take *" ++ name ++
            " as its first parameter and return void";

        comptime {
            if (std.meta.hasFn(T, "init")) {
                const init_info = @typeInfo(@TypeOf(T.init)).@"fn";
                if (init_info.return_type != T) @compileError(init_error_message);
                if (init_info.params.len > 1) @compileError(init_error_message);

                if (init_info.params.len == 1) {
                    const Allocator = init_info.params[0].type orelse @compileError(init_error_message);
                    if (Allocator != std.mem.Allocator) @compileError(init_error_message);
                }
            }

            if (!std.meta.hasFn(T, "build")) @compileError(name ++ " must declare build");
            const build_info = @typeInfo(@TypeOf(T.build)).@"fn";
            if (build_info.params.len == 0 or build_info.params[0].type != *T) {
                @compileError(build_error_message);
            }
            if (build_info.return_type != void) @compileError(build_error_message);
        }

        const plugin = allocator.create(T) catch util.panicOom("PluginRegistry.addPlugin");

        if (std.meta.hasFn(T, "init")) {
            plugin.* = switch (@typeInfo(@TypeOf(T.init)).@"fn".params.len) {
                0 => T.init(),
                1 => T.init(allocator),
                else => unreachable,
            };
        } else {
            plugin.* = .{};
        }

        self.plugins.append(allocator, .{
            .plugin = plugin,
            .deinit = getDeinitFunction(T),
            .destroy = getDestroyFunction(T),
        }) catch util.panicOom("PluginRegistry.addPlugin");

        var arguments: std.meta.ArgsTuple(@TypeOf(T.build)) = undefined;
        inline for (&arguments, 0..) |*argument, index| {
            if (comptime index == 0) {
                argument.* = plugin;
            } else {
                argument.* = resolveParameter(allocator, world, @TypeOf(argument.*));
            }
        }

        @call(.auto, T.build, arguments);
    }
};

test "deinit: frees a plugin that allocated in init" {
    const Plugin = struct {
        buffer: []u8,

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{ .buffer = allocator.alloc(u8, 8) catch util.panicOom("Plugin.init") };
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    registry.addPlugin(std.testing.allocator, &world, Plugin);
    registry.deinit(std.testing.allocator);
}

test "deinit: destroys plugins in reverse registration order" {
    const State = struct {
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
            State.record('a');
        }
    };
    const Second = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(_: *@This()) void {
            State.record('b');
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    registry.addPlugin(std.testing.allocator, &world, First);
    registry.addPlugin(std.testing.allocator, &world, Second);
    registry.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, "ba", &State.order);
}

test "deinit: calls a plugin deinit that takes no allocator" {
    const State = struct {
        var count: usize = 0;
    };
    const Plugin = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}

        pub fn deinit(_: *@This()) void {
            State.count += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();

    registry.addPlugin(std.testing.allocator, &world, Plugin);
    registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, State.count);
}

test "addPlugin: runs an init taking no allocator and stores the plugin" {
    const State = struct {
        var initialized: bool = false;
    };
    const Plugin = struct {
        pub fn init() @This() {
            State.initialized = true;
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expect(State.initialized);
    try std.testing.expectEqual(1, registry.plugins.items.len);
}

test "addPlugin: runs an init taking an allocator" {
    const Plugin = struct {
        ready: bool,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{ .ready = true };
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin);

    const stored: *Plugin = @ptrCast(@alignCast(registry.plugins.items[0].plugin));
    try std.testing.expect(stored.ready);
}

test "addPlugin: calls a build that takes only the plugin" {
    const State = struct {
        var built: bool = false;
    };
    const Plugin = struct {
        ready: bool = true,

        pub fn build(self: *@This()) void {
            State.built = self.ready;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expect(State.built);
}

test "addPlugin: passes only the parameters build declares" {
    const Query = @import("world.zig").Query;

    const State = struct {
        var ran: bool = false;
    };

    const Position = struct { x: f32, y: f32 };

    const Plugin = struct {
        pub fn build(_: *@This(), positions: Query(&.{Position})) void {
            var it = positions.iterator();
            State.ran = it.next() == null;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expect(State.ran);
}

test "addPlugin: resolves a resource parameter for build" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };
    const State = struct {
        var scale: f32 = 0;
    };

    const Plugin = struct {
        pub fn build(_: *@This(), config: Resource(Config)) void {
            State.scale = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    world.addResource(allocator, Config, .{ .scale = 2.5 });

    var registry = PluginRegistry.init();
    defer registry.deinit(allocator);

    registry.addPlugin(allocator, &world, Plugin);

    try std.testing.expectEqual(@as(f32, 2.5), State.scale);
}

test "addPlugin: passes the initialized plugin to build" {
    const WorldRef = struct {
        world: *World,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world };
        }
    };

    const State = struct {
        var seen: ?*World = null;
        var seen_initialized: bool = false;
    };
    const Plugin = struct {
        initialized: bool,

        pub fn init(_: std.mem.Allocator) @This() {
            return .{ .initialized = true };
        }

        pub fn build(self: *@This(), world: WorldRef) void {
            State.seen_initialized = self.initialized;
            State.seen = world.world;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expect(State.seen_initialized);
    try std.testing.expectEqual(&world, State.seen.?);
}

test "addPlugin: stores a plugin that declares no deinit" {
    const Plugin = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expectEqual(1, registry.plugins.items.len);
}

test "addPlugin: adds the same plugin type more than once" {
    const State = struct {
        var init_count: usize = 0;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) @This() {
            State.init_count += 1;
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    registry.addPlugin(std.testing.allocator, &world, Plugin);
    registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expectEqual(2, State.init_count);
    try std.testing.expectEqual(2, registry.plugins.items.len);
}
