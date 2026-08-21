const std = @import("std");

const World = @import("../core/world.zig").World;
const Entities = @import("entities.zig").Entities;
const SystemEntry = @import("../erasure/system_entry.zig").SystemEntry;
const buildSystemEntry = @import("../erasure/system_entry.zig").buildSystemEntry;
const panic = @import("../utils.zig").panic;
const panicOom = @import("../utils.zig").panicOom;

pub const baseline_groups = [_][]const u8{ "one_shots", "pre_update", "update", "post_update" };

pub const Systems = struct {
    pub const State = SystemsState;

    state: *State,

    pub fn fromWorld(_: std.mem.Allocator, world: *World) Systems {
        return .{ .state = &world.systems };
    }

    pub fn add(
        self: Systems,
        allocator: std.mem.Allocator,
        group_name: []const u8,
        comptime function: anytype,
        plugin: anytype,
    ) void {
        self.state.queueSystem(
            allocator,
            group_name,
            buildSystemEntry(function, plugin),
        );
    }

    pub fn declareGroup(self: Systems, allocator: std.mem.Allocator, name: []const u8) void {
        self.state.queueGroup(allocator, name, .end);
    }

    pub fn addGroupBefore(
        self: Systems,
        allocator: std.mem.Allocator,
        anchor: []const u8,
        name: []const u8,
    ) void {
        self.state.queueGroup(allocator, name, .{ .before = anchor });
    }

    pub fn addGroupAfter(
        self: Systems,
        allocator: std.mem.Allocator,
        anchor: []const u8,
        name: []const u8,
    ) void {
        self.state.queueGroup(allocator, name, .{ .after = anchor });
    }
};

const SystemsState = struct {
    groups: std.ArrayList(Group) = .empty,
    commands: std.Deque(SystemCommand) = .empty,

    pub fn init() SystemsState {
        return .{};
    }

    pub fn deinit(self: *SystemsState, allocator: std.mem.Allocator) void {
        for (self.groups.items) |*group| group.deinit(allocator);
        self.groups.deinit(allocator);
        self.deinitPending(allocator);
    }

    pub fn findGroup(self: *SystemsState, name: []const u8) ?*Group {
        const index = self.groupIndex(name) orelse return null;
        return &self.groups.items[index];
    }

    pub fn groupIndex(self: *const Systems.State, name: []const u8) ?usize {
        for (self.groups.items, 0..) |group, index| {
            if (std.mem.eql(u8, group.name, name)) return index;
        }
        return null;
    }

    pub fn declareGroup(self: *SystemsState, allocator: std.mem.Allocator, name: []const u8) void {
        self.insertGroup(allocator, name, self.groups.items.len);
    }

    pub fn addGroupBefore(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        anchor: []const u8,
        name: []const u8,
    ) void {
        self.insertGroup(allocator, name, self.anchorIndex(anchor, name));
    }

    pub fn addGroupAfter(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        anchor: []const u8,
        name: []const u8,
    ) void {
        self.insertGroup(allocator, name, self.anchorIndex(anchor, name) + 1);
    }

    fn anchorIndex(self: *const Systems.State, anchor: []const u8, name: []const u8) usize {
        return self.groupIndex(anchor) orelse panic(
            "cannot place group \"{s}\" relative to \"{s}\", which is not declared",
            .{ name, anchor },
        );
    }

    fn insertGroup(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        name: []const u8,
        index: usize,
    ) void {
        if (self.groupIndex(name) != null) {
            panic("group \"{s}\" is already declared", .{name});
        }

        const owned = allocator.dupe(u8, name) catch panicOom("Systems.State.insertGroup");
        self.groups.insert(allocator, index, .{ .name = owned }) catch
            panicOom("Systems.State.insertGroup");
    }

    pub fn addSystemEntry(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        name: []const u8,
        entry: SystemEntry,
    ) void {
        const group = self.findGroup(name) orelse panic(
            "system registered into group \"{s}\", which is not declared",
            .{name},
        );
        group.systems.append(allocator, entry) catch panicOom("Systems.State.addSystemEntry");
    }

    pub fn deinitPending(self: *SystemsState, allocator: std.mem.Allocator) void {
        while (self.commands.popFront()) |command| {
            switch (command) {
                .declare_group => |declare| freeDeclaration(allocator, declare.name, declare.placement),
                .add_system => |add| allocator.free(add.group),
            }
        }
        self.commands.deinit(allocator);
    }

    pub fn queueGroup(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        name: []const u8,
        placement: Placement,
    ) void {
        const owned_name = allocator.dupe(u8, name) catch panicOom("Systems.State.queueGroup");
        const owned_placement: Placement = switch (placement) {
            .end => .end,
            .before => |anchor| .{ .before = allocator.dupe(u8, anchor) catch
                panicOom("Systems.State.queueGroup") },
            .after => |anchor| .{ .after = allocator.dupe(u8, anchor) catch
                panicOom("Systems.State.queueGroup") },
        };

        self.commands.pushBack(allocator, .{ .declare_group = .{
            .name = owned_name,
            .placement = owned_placement,
        } }) catch panicOom("Systems.State.queueGroup");
    }

    pub fn queueSystem(
        self: *SystemsState,
        allocator: std.mem.Allocator,
        group: []const u8,
        entry: SystemEntry,
    ) void {
        const owned = allocator.dupe(u8, group) catch panicOom("Systems.State.queueSystem");
        self.commands.pushBack(allocator, .{ .add_system = .{
            .group = owned,
            .entry = entry,
        } }) catch panicOom("Systems.State.queueSystem");
    }

    pub fn flushPending(self: *SystemsState, allocator: std.mem.Allocator) void {
        while (self.commands.popFront()) |command| {
            switch (command) {
                .declare_group => |declare| {
                    switch (declare.placement) {
                        .end => self.declareGroup(allocator, declare.name),
                        .before => |anchor| self.addGroupBefore(allocator, anchor, declare.name),
                        .after => |anchor| self.addGroupAfter(allocator, anchor, declare.name),
                    }
                    freeDeclaration(allocator, declare.name, declare.placement);
                },
                .add_system => |add| {
                    self.addSystemEntry(allocator, add.group, add.entry);
                    allocator.free(add.group);
                },
            }
        }
    }
};

const Group = struct {
    name: []const u8,
    systems: std.ArrayList(SystemEntry) = .empty,

    fn deinit(self: *Group, allocator: std.mem.Allocator) void {
        self.systems.deinit(allocator);
        allocator.free(self.name);
    }
};

const Placement = union(enum) {
    end,
    before: []const u8,
    after: []const u8,
};

const SystemCommand = union(enum) {
    declare_group: struct {
        name: []const u8,
        placement: Placement,
    },
    add_system: struct {
        group: []const u8,
        entry: SystemEntry,
    },
};

fn freeDeclaration(allocator: std.mem.Allocator, name: []const u8, placement: Placement) void {
    allocator.free(name);
    switch (placement) {
        .end => {},
        .before, .after => |anchor| allocator.free(anchor),
    }
}

test "addSystemEntry: appends into a declared group" {
    const system = struct {
        fn call(_: std.mem.Allocator) void {}
    }.call;

    var registry = Systems.State.init();
    defer registry.deinit(std.testing.allocator);
    registry.declareGroup(std.testing.allocator, "update");
    registry.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(system, null));

    try std.testing.expectEqual(1, registry.groups.items.len);
    try std.testing.expectEqual(1, registry.findGroup("update").?.systems.items.len);
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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(a, null));
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(b, null));

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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    var plugin = Plugin{};
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(Plugin.update, &plugin));

    world.runSystems(std.testing.allocator);
    try std.testing.expectEqual(1, plugin.calls);
}

test "declareGroup: keeps groups in declaration order" {
    var registry = Systems.State.init();
    defer registry.deinit(std.testing.allocator);
    registry.declareGroup(std.testing.allocator, "physics");
    registry.declareGroup(std.testing.allocator, "update");

    try std.testing.expectEqualStrings("physics", registry.groups.items[0].name);
    try std.testing.expectEqualStrings("update", registry.groups.items[1].name);
}

test "declareGroup: owns the name it is given" {
    var registry = Systems.State.init();
    defer registry.deinit(std.testing.allocator);

    var buffer: [7]u8 = "physics".*;
    registry.declareGroup(std.testing.allocator, &buffer);
    @memset(&buffer, 'x');

    try std.testing.expectEqual(null, registry.groupIndex("xxxxxxx"));
    try std.testing.expect(registry.groupIndex("physics") != null);
}

test "addGroupBefore: inserts at the anchor's index" {
    var registry = Systems.State.init();
    defer registry.deinit(std.testing.allocator);
    registry.declareGroup(std.testing.allocator, "update");
    registry.declareGroup(std.testing.allocator, "post_update");
    registry.addGroupBefore(std.testing.allocator, "update", "physics");

    try std.testing.expectEqualStrings("physics", registry.groups.items[0].name);
    try std.testing.expectEqualStrings("update", registry.groups.items[1].name);
    try std.testing.expectEqualStrings("post_update", registry.groups.items[2].name);
}

test "addGroupAfter: inserts directly after the anchor" {
    var registry = Systems.State.init();
    defer registry.deinit(std.testing.allocator);
    registry.declareGroup(std.testing.allocator, "update");
    registry.declareGroup(std.testing.allocator, "post_update");
    registry.addGroupAfter(std.testing.allocator, "update", "physics");

    try std.testing.expectEqualStrings("update", registry.groups.items[0].name);
    try std.testing.expectEqualStrings("physics", registry.groups.items[1].name);
    try std.testing.expectEqualStrings("post_update", registry.groups.items[2].name);
}

test "addGroupAfter: appends when the anchor is last" {
    var registry = Systems.State.init();
    defer registry.deinit(std.testing.allocator);
    registry.declareGroup(std.testing.allocator, "update");
    registry.addGroupAfter(std.testing.allocator, "update", "physics");

    try std.testing.expectEqualStrings("update", registry.groups.items[0].name);
    try std.testing.expectEqualStrings("physics", registry.groups.items[1].name);
}

test "pending: deinit releases queued commands without applying them" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var state = Systems.State.init();
    state.declareGroup(allocator, "update");
    state.queueSystem(allocator, "update", entry);

    try std.testing.expectEqual(0, state.findGroup("update").?.systems.items.len);

    state.deinit(allocator);
}

test "pending: deinit releases a queued declaration and its anchor" {
    const allocator = std.testing.allocator;

    var state = Systems.State.init();
    state.declareGroup(allocator, "update");
    state.queueGroup(allocator, "physics", .{ .after = "update" });
    state.queueGroup(allocator, "render", .end);

    try std.testing.expectEqual(1, state.groups.items.len);

    state.deinit(allocator);
}

test "pending: declareGroup: defers placement until flush" {
    const allocator = std.testing.allocator;

    var registry = Systems.State.init();
    defer registry.deinit(allocator);
    registry.declareGroup(allocator, "update");
    registry.declareGroup(allocator, "post_update");

    registry.queueGroup(allocator, "physics", .{ .after = "update" });
    try std.testing.expectEqual(2, registry.groups.items.len);

    registry.flushPending(allocator);

    try std.testing.expectEqual(1, registry.groupIndex("physics").?);
    try std.testing.expectEqual(2, registry.groupIndex("post_update").?);
}

test "pending: queueSystem: defers registration until flush" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var registry = Systems.State.init();
    defer registry.deinit(allocator);
    registry.declareGroup(allocator, "update");

    registry.queueSystem(allocator, "update", entry);
    try std.testing.expectEqual(0, registry.findGroup("update").?.systems.items.len);

    registry.flushPending(allocator);

    try std.testing.expectEqual(1, registry.findGroup("update").?.systems.items.len);
}

test "pending: addSystem: owns the group name until the flush" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var registry = Systems.State.init();
    defer registry.deinit(allocator);
    registry.declareGroup(allocator, "physics");

    var buffer: [7]u8 = "physics".*;
    registry.queueSystem(allocator, &buffer, entry);
    @memset(&buffer, 'x');

    registry.flushPending(allocator);

    try std.testing.expectEqual(null, registry.findGroup("xxxxxxx"));
    try std.testing.expectEqual(1, registry.findGroup("physics").?.systems.items.len);
}

test "pending: flush: leaves the queue empty" {
    const allocator = std.testing.allocator;

    const entry: SystemEntry = .{ .function = struct {
        fn call(_: *World, _: std.mem.Allocator) void {}
    }.call };

    var registry = Systems.State.init();
    defer registry.deinit(allocator);
    registry.declareGroup(allocator, "update");

    registry.queueSystem(allocator, "update", entry);
    registry.flushPending(allocator);

    try std.testing.expectEqual(0, registry.commands.len);
}

test "declareGroup: defers the declaration until the queue is flushed" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    const declared = world.systems.groups.items.len;

    Systems.fromWorld(allocator, &world).declareGroup(allocator, "physics");
    try std.testing.expectEqual(declared, world.systems.groups.items.len);

    world.runSystems(allocator);

    try std.testing.expectEqual(declared + 1, world.systems.groups.items.len);
    try std.testing.expectEqualStrings("physics", world.systems.groups.items[declared].name);
}

test "addGroupAfter: places the group directly after its anchor" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).addGroupAfter(allocator, "pre_update", "physics");
    world.runSystems(allocator);

    const index = world.systems.groupIndex("physics").?;
    try std.testing.expectEqualStrings("pre_update", world.systems.groups.items[index - 1].name);
    try std.testing.expectEqualStrings("update", world.systems.groups.items[index + 1].name);
}

test "addGroupBefore: places the group directly before its anchor" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    Systems.fromWorld(allocator, &world).addGroupBefore(allocator, "one_shots", "first");
    world.runSystems(allocator);

    try std.testing.expectEqual(0, world.systems.groupIndex("first").?);
    try std.testing.expectEqual(1, world.systems.groupIndex("one_shots").?);
}

test "declareGroup: owns the name until the flush" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var buffer: [7]u8 = "physics".*;
    Systems.fromWorld(allocator, &world).declareGroup(allocator, &buffer);
    @memset(&buffer, 'x');

    world.runSystems(allocator);

    try std.testing.expectEqual(null, world.systems.groupIndex("xxxxxxx"));
    try std.testing.expect(world.systems.groupIndex("physics") != null);
}

test "addGroupAfter: owns the anchor until the flush" {
    const allocator = std.testing.allocator;

    var world = World.init(allocator);
    defer world.deinit(allocator);

    var anchor: [6]u8 = "update".*;
    Systems.fromWorld(allocator, &world).addGroupAfter(allocator, &anchor, "physics");
    @memset(&anchor, 'x');

    world.runSystems(allocator);

    const index = world.systems.groupIndex("physics").?;
    try std.testing.expectEqualStrings("update", world.systems.groups.items[index - 1].name);
}

test "resolves only the parameters a system declares, in any order" {
    const State = struct {
        var calls: [4]u8 = undefined;
        var count: usize = 0;

        fn record(tag: u8) void {
            calls[count] = tag;
            count += 1;
        }
    };

    const both = struct {
        fn call(_: Entities, _: std.mem.Allocator) void {
            State.record(1);
        }
    }.call;
    const reversed = struct {
        fn call(_: std.mem.Allocator, _: Entities) void {
            State.record(2);
        }
    }.call;
    const commands_only = struct {
        fn call(_: Entities) void {
            State.record(3);
        }
    }.call;
    const nothing = struct {
        fn call() void {
            State.record(4);
        }
    }.call;

    State.count = 0;

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(both, null));
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(reversed, null));
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(commands_only, null));
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(nothing, null));

    world.runSystems(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &State.calls);
}

test "accepts any type declaring fromWorld as a system parameter" {
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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(system, null));

    world.runSystems(std.testing.allocator);

    try std.testing.expectEqual(42, State.seed);
    try std.testing.expectEqual(&world, State.world);
}

test "runs systems group by group, in registration order" {
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

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);
    world.systems.addSystemEntry(std.testing.allocator, "pre_update", buildSystemEntry(a, null));
    world.systems.addSystemEntry(std.testing.allocator, "update", buildSystemEntry(b, null));
    world.systems.addSystemEntry(std.testing.allocator, "pre_update", buildSystemEntry(c, null));

    world.runSystems(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 2 }, &State.calls);
}
