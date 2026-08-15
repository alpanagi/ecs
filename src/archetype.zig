const std = @import("std");

const ComponentData = @import("component.zig").ComponentData;
const ComponentDescriptor = @import("component.zig").ComponentDescriptor;
const Error = @import("error.zig").Error;
const panic = @import("util.zig").panic;
const panicOom = @import("util.zig").panicOom;

const preallocated_entities_count: usize = 16;

pub const Archetype = struct {
    pub const InitOptions = struct {
        capacity: ?usize = null,
    };

    entity_count: u32,
    entity_ids: []u32,

    marker_component_ids: []const u64,
    sized_components: []ComponentDescriptor,
    data: [][]align(64) u8,

    pub fn init(
        allocator: std.mem.Allocator,
        components: []const ComponentDescriptor,
        options: InitOptions,
    ) Archetype {
        const capacity = options.capacity orelse preallocated_entities_count;
        if (capacity == 0) panic("Archetype.init: capacity must be greater than zero", .{});

        var sized_components = std.ArrayList(ComponentDescriptor).initCapacity(allocator, components.len) catch panicOom("Archetype.init");
        var marker_ids = std.ArrayList(u64).initCapacity(allocator, components.len) catch panicOom("Archetype.init");

        for (components) |component| {
            if (component.size % component.alignment != 0) {
                panic(
                    "Archetype.init: component {d} has size {d}, not a multiple of its alignment {d}",
                    .{ component.id, component.size, component.alignment },
                );
            }

            if (component.size > 0) {
                sized_components.appendAssumeCapacity(component);
            } else {
                marker_ids.appendAssumeCapacity(component.id);
            }
        }

        std.sort.pdq(ComponentDescriptor, sized_components.items, {}, ComponentDescriptor.lessThan);
        std.sort.pdq(u64, marker_ids.items, {}, std.sort.asc(u64));

        const data = allocator.alloc([]align(64) u8, sized_components.items.len) catch panicOom("Archetype.init");
        for (sized_components.items, 0..) |component, idx| {
            data[idx] = allocator.alignedAlloc(
                u8,
                .fromByteUnits(64),
                capacity * component.size,
            ) catch panicOom("Archetype.init");
        }

        const entity_ids = allocator.alloc(u32, capacity) catch
            panicOom("Archetype.init");

        return Archetype{
            .entity_count = 0,
            .entity_ids = entity_ids,
            .sized_components = sized_components.toOwnedSlice(allocator) catch panicOom("Archetype.init"),
            .marker_component_ids = marker_ids.toOwnedSlice(allocator) catch panicOom("Archetype.init"),
            .data = data,
        };
    }

    pub fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        for (self.data, self.sized_components) |buffer, component| {
            for (0..self.entity_count) |entity_index| {
                component.deinit(allocator, @ptrCast(&buffer[entity_index * component.size]));
            }
        }

        allocator.free(self.entity_ids);
        for (self.data) |value| allocator.free(value);
        allocator.free(self.data);
        allocator.free(self.sized_components);
        allocator.free(self.marker_component_ids);
    }

    pub fn addEntity(
        self: *Archetype,
        allocator: std.mem.Allocator,
        entity_id: u32,
        component_data: []const ComponentData,
    ) !u32 {
        if (component_data.len != self.sized_components.len + self.marker_component_ids.len)
            return Error.ComponentMismatch;

        const entity_index = self.entity_count;
        if (self.entity_count == self.entity_ids.len) self.growTo(allocator, self.entity_ids.len * 2);

        const row: usize = entity_index;

        for (component_data) |component| {
            if (component.bytes) |bytes| {
                const index = self.findComponentIndex(component.id) orelse return Error.UnknownComponent;
                const size: usize = self.sized_components[index].size;
                if (bytes.len != size) return Error.ComponentMismatch;
                @memcpy(self.data[index][row * size .. (row + 1) * size], bytes);
            } else {
                if (self.findMarkerIndex(component.id) == null) return Error.UnknownComponent;
            }
        }

        self.entity_ids[entity_index] = entity_id;
        self.entity_count += 1;
        return entity_index;
    }

    pub fn removeEntity(self: *Archetype, allocator: std.mem.Allocator, entity_index: u32) ?u32 {
        if (entity_index >= self.entity_count) return null;

        const row: usize = entity_index;

        for (self.data, self.sized_components) |buffer, component| {
            component.deinit(allocator, @ptrCast(&buffer[row * component.size]));
        }

        const last_index = self.entity_count - 1;
        self.entity_count -= 1;

        if (entity_index == last_index) return null;

        const last_row: usize = last_index;

        for (self.data, self.sized_components) |buffer, component| {
            const size: usize = component.size;
            @memcpy(
                buffer[row * size .. (row + 1) * size],
                buffer[last_row * size .. (last_row + 1) * size],
            );
        }

        const relocated_entity = self.entity_ids[last_index];
        self.entity_ids[entity_index] = relocated_entity;
        return relocated_entity;
    }

    pub fn getComponentBytes(self: *Archetype, entity_index: u32, component_id: u64) ?[]u8 {
        if (entity_index >= self.entity_count) {
            panic("Archetype.getComponentBytes: entity index {d} is out of bounds, the archetype has {d} entities", .{ entity_index, self.entity_count });
        }

        const index = self.findComponentIndex(component_id) orelse return null;
        const row: usize = entity_index;
        const size: usize = self.sized_components[index].size;
        return self.data[index][row * size .. (row + 1) * size];
    }

    pub fn hasComponent(self: *const Archetype, component_id: u64) bool {
        if (self.findMarkerIndex(component_id) != null) return true;
        if (self.findComponentIndex(component_id) != null) return true;
        return false;
    }

    fn growTo(self: *Archetype, allocator: std.mem.Allocator, new_capacity: usize) void {
        self.entity_ids = allocator.realloc(self.entity_ids, new_capacity) catch
            panicOom("Archetype.growTo");

        for (self.data, self.sized_components) |*buffer, component| {
            buffer.* = allocator.realloc(buffer.*, new_capacity * component.size) catch
                panicOom("Archetype.growTo");
        }
    }

    fn findComponentIndex(self: *const Archetype, component_id: u64) ?usize {
        return std.sort.binarySearch(ComponentDescriptor, self.sized_components, component_id, ComponentDescriptor.orderById);
    }

    fn findMarkerIndex(self: *const Archetype, component_id: u64) ?usize {
        return std.sort.binarySearch(u64, self.marker_component_ids, component_id, struct {
            fn order(context: u64, item: u64) std.math.Order {
                return std.math.order(context, item);
            }
        }.order);
    }
};

test "init: sorts sized components by id" {
    const allocator = std.testing.allocator;

    const First = struct { value: u64 };
    const Second = struct { data: [33]u8 };

    const first = ComponentDescriptor.from(First);
    const second = ComponentDescriptor.from(Second);

    var forward = Archetype.init(allocator, &.{ first, second }, .{});
    defer forward.deinit(allocator);

    var reverse = Archetype.init(allocator, &.{ second, first }, .{});
    defer reverse.deinit(allocator);

    try std.testing.expect(forward.sized_components[0].id < forward.sized_components[1].id);
    try std.testing.expectEqual(forward.sized_components[0].id, reverse.sized_components[0].id);
    try std.testing.expectEqual(forward.sized_components[1].id, reverse.sized_components[1].id);
}

test "init: sorts marker component ids" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Frozen = struct {};

    const player = ComponentDescriptor.from(Player);
    const frozen = ComponentDescriptor.from(Frozen);

    var forward = Archetype.init(allocator, &.{ player, frozen }, .{});
    defer forward.deinit(allocator);

    var reverse = Archetype.init(allocator, &.{ frozen, player }, .{});
    defer reverse.deinit(allocator);

    try std.testing.expect(forward.marker_component_ids[0] < forward.marker_component_ids[1]);
    try std.testing.expectEqualSlices(u64, forward.marker_component_ids, reverse.marker_component_ids);
}

test "init: keeps marker components out of the sized components" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    const player = ComponentDescriptor.from(Player);
    const position = ComponentDescriptor.from(Position);

    var archetype = Archetype.init(allocator, &.{ player, position }, .{});
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(1, archetype.sized_components.len);
    try std.testing.expectEqual(position.id, archetype.sized_components[0].id);
    try std.testing.expectEqualSlices(u64, &.{player.id}, archetype.marker_component_ids);
}

test "init: allocates one data buffer per sized component" {
    const allocator = std.testing.allocator;

    const Small = struct { value: u64 };
    const Large = struct { data: [33]u8 };

    var archetype = Archetype.init(
        allocator,
        &.{ ComponentDescriptor.from(Small), ComponentDescriptor.from(Large) },
        .{},
    );
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(2, archetype.data.len);
    for (archetype.data, archetype.sized_components) |buffer, component| {
        try std.testing.expectEqual(preallocated_entities_count * component.size, buffer.len);
    }
}

test "init: allocates no data buffer for a marker only archetype" {
    const allocator = std.testing.allocator;

    const Player = struct {};

    var archetype = Archetype.init(allocator, &.{ComponentDescriptor.from(Player)}, .{});
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(0, archetype.data.len);
    try std.testing.expectEqual(0, archetype.sized_components.len);
    try std.testing.expectEqual(preallocated_entities_count, archetype.entity_ids.len);
}

test "init: preallocates the default capacity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = Archetype.init(allocator, &.{ComponentDescriptor.from(Value)}, .{});
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(0, archetype.entity_count);
    try std.testing.expectEqual(preallocated_entities_count, archetype.entity_ids.len);
    try std.testing.expectEqual(preallocated_entities_count * @sizeOf(Value), archetype.data[0].len);
}

test "init: reserves the requested capacity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = Archetype.init(allocator, &.{ComponentDescriptor.from(Value)}, .{ .capacity = 64 });
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(64, archetype.entity_ids.len);
    try std.testing.expectEqual(64 * @sizeOf(Value), archetype.data[0].len);
}

test "init: accepts an archetype with no components" {
    const allocator = std.testing.allocator;

    var archetype = Archetype.init(allocator, &.{}, .{});
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(0, archetype.data.len);
    try std.testing.expectEqual(0, archetype.sized_components.len);
    try std.testing.expectEqual(0, archetype.marker_component_ids.len);

    try std.testing.expectEqual(0, try archetype.addEntity(allocator, 7, &.{}));
    try std.testing.expectEqual(7, archetype.entity_ids[0]);
}

test "deinit: calls deinit on every stored component" {
    const allocator = std.testing.allocator;

    const Counted = struct {
        var calls: usize = 0;

        value: u32,

        pub fn deinit(_: *@This()) void {
            calls += 1;
        }
    };

    const counted = ComponentDescriptor.from(Counted);

    var archetype = Archetype.init(allocator, &.{counted}, .{});

    const first = Counted{ .value = 1 };
    const second = Counted{ .value = 2 };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = counted.id, .bytes = std.mem.asBytes(&first) }});
    _ = try archetype.addEntity(allocator, 1, &.{.{ .id = counted.id, .bytes = std.mem.asBytes(&second) }});

    archetype.deinit(allocator);

    try std.testing.expectEqual(2, Counted.calls);
}

test "deinit: frees memory owned by stored components" {
    const allocator = std.testing.allocator;

    const Owning = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.buffer);
        }
    };

    const owning = ComponentDescriptor.from(Owning);

    var archetype = Archetype.init(allocator, &.{owning}, .{});

    const value = Owning{ .buffer = try allocator.alloc(u8, 8) };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = owning.id, .bytes = std.mem.asBytes(&value) }});

    archetype.deinit(allocator);
}

test "deinit: ignores rows past the entity count" {
    const allocator = std.testing.allocator;

    const Counted = struct {
        var calls: usize = 0;

        value: u32,

        pub fn deinit(_: *@This()) void {
            calls += 1;
        }
    };

    const counted = ComponentDescriptor.from(Counted);

    var archetype = Archetype.init(allocator, &.{counted}, .{ .capacity = 8 });

    const value = Counted{ .value = 1 };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = counted.id, .bytes = std.mem.asBytes(&value) }});

    archetype.deinit(allocator);

    try std.testing.expectEqual(1, Counted.calls);
}

test "deinit: frees memory owned by two different components" {
    const allocator = std.testing.allocator;

    const Owning = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.buffer);
        }
    };
    const AlsoOwning = struct {
        name: []u8,
        tag: u32,

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.name);
        }
    };

    const owning = ComponentDescriptor.from(Owning);
    const also_owning = ComponentDescriptor.from(AlsoOwning);

    var archetype = Archetype.init(allocator, &.{ owning, also_owning }, .{});

    const first = Owning{ .buffer = try allocator.alloc(u8, 8) };
    const second = AlsoOwning{ .name = try allocator.alloc(u8, 16), .tag = 1 };
    _ = try archetype.addEntity(allocator, 0, &.{
        .{ .id = owning.id, .bytes = std.mem.asBytes(&first) },
        .{ .id = also_owning.id, .bytes = std.mem.asBytes(&second) },
    });

    archetype.deinit(allocator);
}

test "addEntity: returns the index the entity was stored at" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const first = Value{ .value = 1 };
    const second = Value{ .value = 2 };

    try std.testing.expectEqual(
        0,
        try archetype.addEntity(allocator, 10, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&first) }}),
    );
    try std.testing.expectEqual(
        1,
        try archetype.addEntity(allocator, 11, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&second) }}),
    );
    try std.testing.expectEqual(2, archetype.entity_count);
}

test "addEntity: stores the entity id at the returned index" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const stored = Value{ .value = 1 };
    const index = try archetype.addEntity(allocator, 42, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&stored) }});

    try std.testing.expectEqual(42, archetype.entity_ids[index]);
}

test "addEntity: copies the bytes into the column matching each component" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Health = struct { points: u64 };

    const position = ComponentDescriptor.from(Position);
    const health = ComponentDescriptor.from(Health);

    var archetype = Archetype.init(allocator, &.{ position, health }, .{});
    defer archetype.deinit(allocator);

    const stored_position = Position{ .x = 1, .y = 2 };
    const stored_health = Health{ .points = 99 };
    _ = try archetype.addEntity(allocator, 0, &.{
        .{ .id = position.id, .bytes = std.mem.asBytes(&stored_position) },
        .{ .id = health.id, .bytes = std.mem.asBytes(&stored_health) },
    });

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&stored_position),
        archetype.getComponentBytes(0, position.id).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&stored_health),
        archetype.getComponentBytes(0, health.id).?,
    );
}

test "addEntity: ignores the order the component data is passed in" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Health = struct { points: u64 };

    const position = ComponentDescriptor.from(Position);
    const health = ComponentDescriptor.from(Health);

    var archetype = Archetype.init(allocator, &.{ position, health }, .{});
    defer archetype.deinit(allocator);

    const stored_position = Position{ .x = 1, .y = 2 };
    const stored_health = Health{ .points = 99 };
    _ = try archetype.addEntity(allocator, 0, &.{
        .{ .id = health.id, .bytes = std.mem.asBytes(&stored_health) },
        .{ .id = position.id, .bytes = std.mem.asBytes(&stored_position) },
    });

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&stored_position),
        archetype.getComponentBytes(0, position.id).?,
    );
}

test "addEntity: accepts a marker component carrying no bytes" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    const player = ComponentDescriptor.from(Player);
    const position = ComponentDescriptor.from(Position);

    var archetype = Archetype.init(allocator, &.{ player, position }, .{});
    defer archetype.deinit(allocator);

    const stored = Position{ .x = 1, .y = 2 };
    _ = try archetype.addEntity(allocator, 0, &.{
        .{ .id = player.id, .bytes = null },
        .{ .id = position.id, .bytes = std.mem.asBytes(&stored) },
    });

    try std.testing.expectEqual(1, archetype.entity_count);
}

test "addEntity: returns ComponentMismatch when a component is missing" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    const position = ComponentDescriptor.from(Position);

    var archetype = Archetype.init(allocator, &.{ ComponentDescriptor.from(Player), position }, .{});
    defer archetype.deinit(allocator);

    const stored = Position{ .x = 1, .y = 2 };

    try std.testing.expectError(
        Error.ComponentMismatch,
        archetype.addEntity(allocator, 0, &.{.{ .id = position.id, .bytes = std.mem.asBytes(&stored) }}),
    );
}

test "addEntity: returns ComponentMismatch when the byte length differs from the component size" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const position = ComponentDescriptor.from(Position);

    var archetype = Archetype.init(allocator, &.{position}, .{});
    defer archetype.deinit(allocator);

    const truncated: []const u8 = &.{ 0, 0, 0 };

    try std.testing.expectError(
        Error.ComponentMismatch,
        archetype.addEntity(allocator, 0, &.{.{ .id = position.id, .bytes = truncated }}),
    );
}

test "addEntity: returns UnknownComponent for a component the archetype does not have" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var archetype = Archetype.init(allocator, &.{ComponentDescriptor.from(Position)}, .{});
    defer archetype.deinit(allocator);

    const stored = Velocity{ .dx = 1, .dy = 2 };

    try std.testing.expectError(
        Error.UnknownComponent,
        archetype.addEntity(allocator, 0, &.{
            .{ .id = ComponentDescriptor.from(Velocity).id, .bytes = std.mem.asBytes(&stored) },
        }),
    );
}

test "addEntity: returns UnknownComponent for a marker the archetype does not have" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Frozen = struct {};

    var archetype = Archetype.init(allocator, &.{ComponentDescriptor.from(Player)}, .{});
    defer archetype.deinit(allocator);

    try std.testing.expectError(
        Error.UnknownComponent,
        archetype.addEntity(allocator, 0, &.{
            .{ .id = ComponentDescriptor.from(Frozen).id, .bytes = null },
        }),
    );
}

test "addEntity: returns UnknownComponent when a sized component carries no bytes" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const position = ComponentDescriptor.from(Position);

    var archetype = Archetype.init(allocator, &.{position}, .{});
    defer archetype.deinit(allocator);

    try std.testing.expectError(
        Error.UnknownComponent,
        archetype.addEntity(allocator, 0, &.{.{ .id = position.id, .bytes = null }}),
    );
}

test "addEntity: returns UnknownComponent when a marker carries bytes" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const player = ComponentDescriptor.from(Player);

    var archetype = Archetype.init(allocator, &.{player}, .{});
    defer archetype.deinit(allocator);

    const bytes: []const u8 = &.{0};

    try std.testing.expectError(
        Error.UnknownComponent,
        archetype.addEntity(allocator, 0, &.{.{ .id = player.id, .bytes = bytes }}),
    );
}

test "addEntity: grows the arrays when the capacity is exhausted" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const count = preallocated_entities_count + 1;

    for (0..count) |index| {
        const stored = Value{ .value = @intCast(index) };
        _ = try archetype.addEntity(allocator, @intCast(index), &.{
            .{ .id = value.id, .bytes = std.mem.asBytes(&stored) },
        });
    }

    try std.testing.expectEqual(count, archetype.entity_count);
    try std.testing.expect(archetype.entity_ids.len > preallocated_entities_count);
    try std.testing.expect(archetype.data[0].len >= count * @sizeOf(Value));

    for (0..count) |index| {
        const expected = Value{ .value = @intCast(index) };
        try std.testing.expectEqual(@as(u32, @intCast(index)), archetype.entity_ids[index]);
        try std.testing.expectEqualSlices(
            u8,
            std.mem.asBytes(&expected),
            archetype.getComponentBytes(@intCast(index), value.id).?,
        );
    }
}

test "addEntity: grows a marker only archetype" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const player = ComponentDescriptor.from(Player);

    var archetype = Archetype.init(allocator, &.{player}, .{});
    defer archetype.deinit(allocator);

    const count = preallocated_entities_count + 1;

    for (0..count) |index| {
        _ = try archetype.addEntity(allocator, @intCast(index), &.{.{ .id = player.id, .bytes = null }});
    }

    try std.testing.expectEqual(count, archetype.entity_count);
    try std.testing.expect(archetype.entity_ids.len > preallocated_entities_count);
    try std.testing.expectEqual(0, archetype.data.len);

    for (0..count) |index| {
        try std.testing.expectEqual(@as(u32, @intCast(index)), archetype.entity_ids[index]);
    }
}

test "removeEntity: returns null when the index is out of bounds" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const stored = Value{ .value = 1 };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&stored) }});

    try std.testing.expectEqual(null, archetype.removeEntity(allocator, 1));
    try std.testing.expectEqual(1, archetype.entity_count);
}

test "removeEntity: returns null when the removed entity is the last row" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const first = Value{ .value = 1 };
    const second = Value{ .value = 2 };
    _ = try archetype.addEntity(allocator, 10, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&first) }});
    const last = try archetype.addEntity(allocator, 11, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&second) }});

    try std.testing.expectEqual(null, archetype.removeEntity(allocator, last));
    try std.testing.expectEqual(1, archetype.entity_count);
}

test "removeEntity: returns the id of the entity moved into the removed row" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const first = Value{ .value = 1 };
    const second = Value{ .value = 2 };
    const removed = try archetype.addEntity(allocator, 10, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&first) }});
    _ = try archetype.addEntity(allocator, 11, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&second) }});

    try std.testing.expectEqual(11, archetype.removeEntity(allocator, removed));
    try std.testing.expectEqual(1, archetype.entity_count);
    try std.testing.expectEqual(11, archetype.entity_ids[removed]);
}

test "removeEntity: moves the last row's component bytes into the removed row" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const first = Value{ .value = 10 };
    const second = Value{ .value = 20 };
    const removed = try archetype.addEntity(allocator, 0, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&first) }});
    _ = try archetype.addEntity(allocator, 1, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&second) }});

    _ = archetype.removeEntity(allocator, removed);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&second),
        archetype.getComponentBytes(removed, value.id).?,
    );
}

test "removeEntity: moves only the last row when removing from the middle" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const first = Value{ .value = 100 };
    const second = Value{ .value = 200 };
    const third = Value{ .value = 300 };
    const removed = try archetype.addEntity(allocator, 10, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&first) }});
    const kept = try archetype.addEntity(allocator, 11, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&second) }});
    _ = try archetype.addEntity(allocator, 12, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&third) }});

    try std.testing.expectEqual(12, archetype.removeEntity(allocator, removed));
    try std.testing.expectEqual(2, archetype.entity_count);

    try std.testing.expectEqual(12, archetype.entity_ids[removed]);
    try std.testing.expectEqual(11, archetype.entity_ids[kept]);

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&third),
        archetype.getComponentBytes(removed, value.id).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&second),
        archetype.getComponentBytes(kept, value.id).?,
    );
}

test "removeEntity: moves every column when removing from the middle" {
    const allocator = std.testing.allocator;

    const Small = struct { value: u32 };
    const Large = struct { data: [16]u8 };

    const small = ComponentDescriptor.from(Small);
    const large = ComponentDescriptor.from(Large);

    var archetype = Archetype.init(allocator, &.{ small, large }, .{});
    defer archetype.deinit(allocator);

    const smalls = [_]Small{ .{ .value = 10 }, .{ .value = 20 }, .{ .value = 30 } };
    const larges = [_]Large{
        .{ .data = @splat(1) },
        .{ .data = @splat(2) },
        .{ .data = @splat(3) },
    };

    var rows: [3]u32 = undefined;
    for (0..3) |index| {
        rows[index] = try archetype.addEntity(allocator, @intCast(index), &.{
            .{ .id = small.id, .bytes = std.mem.asBytes(&smalls[index]) },
            .{ .id = large.id, .bytes = std.mem.asBytes(&larges[index]) },
        });
    }

    try std.testing.expectEqual(2, archetype.removeEntity(allocator, rows[0]));

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&smalls[2]),
        archetype.getComponentBytes(rows[0], small.id).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&larges[2]),
        archetype.getComponentBytes(rows[0], large.id).?,
    );

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&smalls[1]),
        archetype.getComponentBytes(rows[1], small.id).?,
    );
    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&larges[1]),
        archetype.getComponentBytes(rows[1], large.id).?,
    );
}

test "removeEntity: is a no op when the row was already removed" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const first = Value{ .value = 1 };
    const second = Value{ .value = 2 };
    _ = try archetype.addEntity(allocator, 10, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&first) }});
    const last = try archetype.addEntity(allocator, 11, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&second) }});

    try std.testing.expectEqual(null, archetype.removeEntity(allocator, last));
    try std.testing.expectEqual(null, archetype.removeEntity(allocator, last));
    try std.testing.expectEqual(1, archetype.entity_count);
    try std.testing.expectEqual(10, archetype.entity_ids[0]);
}

test "removeEntity: calls deinit only on the removed row" {
    const allocator = std.testing.allocator;

    const Counted = struct {
        var calls: usize = 0;

        value: u32,

        pub fn deinit(_: *@This()) void {
            calls += 1;
        }
    };

    const counted = ComponentDescriptor.from(Counted);

    var archetype = Archetype.init(allocator, &.{counted}, .{});
    defer archetype.deinit(allocator);

    const first = Counted{ .value = 1 };
    const second = Counted{ .value = 2 };
    const removed = try archetype.addEntity(allocator, 0, &.{.{ .id = counted.id, .bytes = std.mem.asBytes(&first) }});
    _ = try archetype.addEntity(allocator, 1, &.{.{ .id = counted.id, .bytes = std.mem.asBytes(&second) }});

    _ = archetype.removeEntity(allocator, removed);

    try std.testing.expectEqual(1, Counted.calls);
}

test "removeEntity: frees memory owned by the removed row" {
    const allocator = std.testing.allocator;

    const Owning = struct {
        buffer: []u8,

        pub fn deinit(self: *@This(), inner: std.mem.Allocator) void {
            inner.free(self.buffer);
        }
    };

    const owning = ComponentDescriptor.from(Owning);

    var archetype = Archetype.init(allocator, &.{owning}, .{});
    defer archetype.deinit(allocator);

    const first = Owning{ .buffer = try allocator.alloc(u8, 8) };
    const second = Owning{ .buffer = try allocator.alloc(u8, 16) };
    const removed = try archetype.addEntity(allocator, 0, &.{.{ .id = owning.id, .bytes = std.mem.asBytes(&first) }});
    _ = try archetype.addEntity(allocator, 1, &.{.{ .id = owning.id, .bytes = std.mem.asBytes(&second) }});

    _ = archetype.removeEntity(allocator, removed);
}

test "removeEntity: relocates the entity id in a marker only archetype" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const player = ComponentDescriptor.from(Player);

    var archetype = Archetype.init(allocator, &.{player}, .{});
    defer archetype.deinit(allocator);

    const removed = try archetype.addEntity(allocator, 10, &.{.{ .id = player.id, .bytes = null }});
    _ = try archetype.addEntity(allocator, 11, &.{.{ .id = player.id, .bytes = null }});

    try std.testing.expectEqual(11, archetype.removeEntity(allocator, removed));
    try std.testing.expectEqual(1, archetype.entity_count);
    try std.testing.expectEqual(11, archetype.entity_ids[removed]);
}

test "getComponentBytes: returns the bytes stored for a component" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const stored = Value{ .value = 7 };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&stored) }});

    const bytes = archetype.getComponentBytes(0, value.id).?;

    try std.testing.expectEqual(@sizeOf(Value), bytes.len);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&stored), bytes);
}

test "getComponentBytes: returns the bytes of the requested row" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const first = Value{ .value = 10 };
    const second = Value{ .value = 20 };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&first) }});
    const index = try archetype.addEntity(allocator, 1, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&second) }});

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&second),
        archetype.getComponentBytes(index, value.id).?,
    );
}

test "getComponentBytes: writes through to the stored component" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };
    const value = ComponentDescriptor.from(Value);

    var archetype = Archetype.init(allocator, &.{value}, .{});
    defer archetype.deinit(allocator);

    const stored = Value{ .value = 1 };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = value.id, .bytes = std.mem.asBytes(&stored) }});

    const updated = Value{ .value = 2 };
    @memcpy(archetype.getComponentBytes(0, value.id).?, std.mem.asBytes(&updated));

    try std.testing.expectEqualSlices(
        u8,
        std.mem.asBytes(&updated),
        archetype.getComponentBytes(0, value.id).?,
    );
}

test "getComponentBytes: returns null for a component the archetype does not have" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    const position = ComponentDescriptor.from(Position);

    var archetype = Archetype.init(allocator, &.{position}, .{});
    defer archetype.deinit(allocator);

    const stored = Position{ .x = 1, .y = 2 };
    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = position.id, .bytes = std.mem.asBytes(&stored) }});

    try std.testing.expectEqual(null, archetype.getComponentBytes(0, ComponentDescriptor.from(Velocity).id));
}

test "getComponentBytes: returns null for a marker component" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const player = ComponentDescriptor.from(Player);

    var archetype = Archetype.init(allocator, &.{player}, .{});
    defer archetype.deinit(allocator);

    _ = try archetype.addEntity(allocator, 0, &.{.{ .id = player.id, .bytes = null }});

    try std.testing.expectEqual(null, archetype.getComponentBytes(0, player.id));
}

test "hasComponent: returns true for a sized component" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const position = ComponentDescriptor.from(Position);

    var archetype = Archetype.init(allocator, &.{position}, .{});
    defer archetype.deinit(allocator);

    try std.testing.expect(archetype.hasComponent(position.id));
}

test "hasComponent: returns true for a marker component" {
    const allocator = std.testing.allocator;

    const Player = struct {};
    const Position = struct { x: f32, y: f32 };

    const player = ComponentDescriptor.from(Player);

    var archetype = Archetype.init(allocator, &.{ player, ComponentDescriptor.from(Position) }, .{});
    defer archetype.deinit(allocator);

    try std.testing.expect(archetype.hasComponent(player.id));
}

test "hasComponent: returns false for a component the archetype does not have" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Frozen = struct {};

    var archetype = Archetype.init(allocator, &.{ComponentDescriptor.from(Position)}, .{});
    defer archetype.deinit(allocator);

    try std.testing.expect(!archetype.hasComponent(ComponentDescriptor.from(Velocity).id));
    try std.testing.expect(!archetype.hasComponent(ComponentDescriptor.from(Frozen).id));
}
