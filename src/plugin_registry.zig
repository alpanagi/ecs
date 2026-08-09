const std = @import("std");

const World = @import("world.zig").World;
const DeinitFunction = @import("deinit.zig").DeinitFunction;
const getDeinitFunction = @import("deinit.zig").getDeinitFunction;
const deinitIfPresent = @import("deinit.zig").deinitIfPresent;
const resolveParameter = @import("parameter.zig").resolveParameter;
const Resource = @import("world.zig").Resource;

const PluginEntry = struct {
    plugin: *anyopaque,
    deinit: DeinitFunction,
};

pub const PluginRegistry = struct {
    plugins: std.ArrayList(PluginEntry) = .empty,

    pub fn init() PluginRegistry {
        return PluginRegistry{};
    }

    pub fn deinit(self: *PluginRegistry, allocator: std.mem.Allocator) void {
        for (self.plugins.items) |entry| entry.deinit(entry.plugin, allocator);
        self.plugins.deinit(allocator);
    }

    pub fn addPlugin(
        self: *PluginRegistry,
        allocator: std.mem.Allocator,
        world: *World,
        comptime T: type,
    ) !void {
        const plugin = try allocator.create(T);
        {
            errdefer allocator.destroy(plugin);

            if (std.meta.hasFn(T, "init")) {
                const params = @typeInfo(@TypeOf(T.init)).@"fn".params;
                plugin.* = switch (params.len) {
                    0 => try T.init(),
                    1 => try T.init(allocator),
                    else => @compileError(@typeName(T) ++ ".init has an unsupported signature"),
                };
            } else {
                plugin.* = .{};
            }
            errdefer deinitIfPresent(T, plugin, allocator);

            try self.plugins.append(allocator, .{
                .plugin = plugin,
                .deinit = getDeinitFunction(T),
            });
        }

        if (!std.meta.hasFn(T, "build")) {
            @compileError(@typeName(T) ++ " must declare build");
        }

        const build_parameters = @typeInfo(@TypeOf(T.build)).@"fn".params;
        if (build_parameters.len == 0 or build_parameters[0].type.? != *T) {
            @compileError(@typeName(T) ++ ".build must take *" ++ @typeName(T) ++ " as its first parameter");
        }

        var arguments: std.meta.ArgsTuple(@TypeOf(T.build)) = undefined;
        inline for (&arguments, 0..) |*argument, index| {
            if (comptime index == 0) {
                argument.* = plugin;
            } else {
                argument.* = resolveParameter(@TypeOf(argument.*), allocator, world);
            }
        }
        try @call(.auto, T.build, arguments);
    }
};

test "a plugin's build may declare only the parameters it needs" {
    const Query = @import("world.zig").Query;

    const State = struct {
        var ran: bool = false;
    };
    State.ran = false;

    const Position = struct { x: f32, y: f32 };

    const Plugin = struct {
        pub fn build(_: *@This(), positions: Query(&.{Position})) !void {
            var it = positions.iterator();
            State.ran = it.next() == null;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    try world.addPlugin(std.testing.allocator, Plugin);

    try std.testing.expect(State.ran);
}

test "a plugin's build can declare a resource dependency" {
    const allocator = std.testing.allocator;

    const Config = struct { scale: f32 };
    const State = struct {
        var scale: f32 = 0;
    };
    State.scale = 0;

    const Plugin = struct {
        pub fn build(_: *@This(), config: Resource(Config)) !void {
            State.scale = config.value.scale;
        }
    };

    var world = World.init();
    defer world.deinit(allocator);

    try world.addResource(allocator, Config, .{ .scale = 2.5 });
    try world.addPlugin(allocator, Plugin);

    try std.testing.expectEqual(@as(f32, 2.5), State.scale);
}

test "addPlugin runs the plugin's init immediately and stores it" {
    const State = struct {
        var initialized: bool = false;
    };
    const Plugin = struct {
        pub fn init() !@This() {
            State.initialized = true;
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expect(State.initialized);
    try std.testing.expectEqual(1, registry.plugins.items.len);
}

test "a plugin's build receives the initialized plugin and world" {
    const WorldRef = struct {
        world: *World,

        pub fn fromWorld(_: std.mem.Allocator, world: *World) @This() {
            return .{ .world = world };
        }
    };

    const State = struct {
        var seen: ?*World = null;
    };
    const Plugin = struct {
        initialized: bool,

        pub fn init(_: std.mem.Allocator) !@This() {
            return .{ .initialized = true };
        }

        pub fn build(self: *@This(), world: WorldRef) !void {
            try std.testing.expect(self.initialized);
            State.seen = world.world;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expectEqual(&world, State.seen.?);
}

test "a plugin can allocate state in init and free it in deinit" {
    const Plugin = struct {
        buffer: []u8,

        pub fn init(allocator: std.mem.Allocator) !@This() {
            return .{ .buffer = try allocator.alloc(u8, 8) };
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    try registry.addPlugin(std.testing.allocator, &world, Plugin);
    registry.deinit(std.testing.allocator);
}

test "deinit calls each plugin's deinit" {
    const State = struct {
        var count: usize = 0;
    };
    const PluginA = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            State.count += 1;
        }
    };
    const PluginB = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            State.count += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();

    try registry.addPlugin(std.testing.allocator, &world, PluginA);
    try registry.addPlugin(std.testing.allocator, &world, PluginB);
    registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, State.count);
}

test "the same plugin type can currently be added more than once" {
    const State = struct {
        var init_count: usize = 0;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            State.init_count += 1;
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addPlugin(std.testing.allocator, &world, Plugin);
    try registry.addPlugin(std.testing.allocator, &world, Plugin);
    try std.testing.expectEqual(2, State.init_count);
    try std.testing.expectEqual(2, registry.plugins.items.len);
}

test "deinit supports a plugin deinit that takes no allocator" {
    const State = struct {
        var count: usize = 0;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn deinit(_: *@This()) void {
            State.count += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();

    try registry.addPlugin(std.testing.allocator, &world, Plugin);
    registry.deinit(std.testing.allocator);

    try std.testing.expectEqual(1, State.count);
}

test "a plugin without a deinit is added and freed without error" {
    const Plugin = struct {
        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try registry.addPlugin(std.testing.allocator, &world, Plugin);

    try std.testing.expectEqual(1, registry.plugins.items.len);
}

test "addPlugin propagates an init error and stores nothing" {
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            return error.Boom;
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.Boom,
        registry.addPlugin(std.testing.allocator, &world, Plugin),
    );

    try std.testing.expectEqual(0, registry.plugins.items.len);
}

test "a failed init does not trigger the plugin's deinit" {
    const State = struct {
        var deinit_count: usize = 0;
    };
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            return error.Boom;
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {}

        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {
            State.deinit_count += 1;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);

    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.Boom,
        registry.addPlugin(std.testing.allocator, &world, Plugin),
    );

    try std.testing.expectEqual(0, State.deinit_count);
}

test "a plugin remains stored when its build fails" {
    const Plugin = struct {
        pub fn init(_: std.mem.Allocator) !@This() {
            return .{};
        }

        pub fn build(_: *@This(), _: std.mem.Allocator) !void {
            return error.Boom;
        }
    };

    var world = World.init();
    defer world.deinit(std.testing.allocator);
    var registry = PluginRegistry.init();
    defer registry.deinit(std.testing.allocator);

    try std.testing.expectError(
        error.Boom,
        registry.addPlugin(std.testing.allocator, &world, Plugin),
    );
    try std.testing.expectEqual(1, registry.plugins.items.len);
}