const std = @import("std");

const Error = @import("error.zig").Error;
const Entity = @import("entity.zig").Entity;
const EntityComponents = @import("util.zig").EntityComponents;
const hash = @import("hash.zig").hash;
const panic = @import("util.zig").panic;
const sortMultiple = @import("sort.zig").sortMultiple;

const preallocated_entities_count: usize = 16;

pub const LifecycleFunction = *const fn (*anyopaque, std.mem.Allocator, Entity) void;

pub const LifecycleFunctions = struct {
    added: LifecycleFunction,
    destroying: LifecycleFunction,
};

pub const Archetype = struct {
    entity_count: u32,
    entities: []Entity,

    component_ids: []const u64,
    component_sizes: []const u32,
    component_deinits: []const ?DeinitFunction,
    component_added: []const LifecycleFunction,
    component_destroying: []const LifecycleFunction,
    data: [][]align(64) u8,

    pub fn init(
        allocator: std.mem.Allocator,
        comptime components: []const type,
        capacity: ?usize,
        comptime lifecycleFunctionsFor: fn (comptime component: type) LifecycleFunctions,
    ) !Archetype {
        const component_ids = try allocator.alloc(u64, components.len);
        errdefer allocator.free(component_ids);
        inline for (components, 0..) |component, idx| component_ids[idx] = hash(component);

        const component_sizes = try allocator.alloc(u32, components.len);
        errdefer allocator.free(component_sizes);
        inline for (components, 0..) |component, idx| component_sizes[idx] = @sizeOf(component);

        const component_deinits = try allocator.alloc(?DeinitFunction, components.len);
        errdefer allocator.free(component_deinits);
        inline for (components, 0..) |component, idx| {
            component_deinits[idx] = getDeinitFunctionFor(component);
        }

        const component_added = try allocator.alloc(LifecycleFunction, components.len);
        errdefer allocator.free(component_added);
        const component_destroying = try allocator.alloc(LifecycleFunction, components.len);
        errdefer allocator.free(component_destroying);
        inline for (components, 0..) |component, idx| {
            const functions = lifecycleFunctionsFor(component);
            component_added[idx] = functions.added;
            component_destroying[idx] = functions.destroying;
        }

        // Alignment here to optimize cache reads.
        const data = try allocator.alloc([]align(64) u8, components.len);
        errdefer allocator.free(data);

        var allocated: usize = 0;
        errdefer for (data[0..allocated]) |buffer| allocator.free(buffer);

        inline for (components, 0..) |component, idx| {
            data[idx] = try allocator.alignedAlloc(
                u8,
                std.mem.Alignment.fromByteUnits(64),
                preallocated_entities_count * @sizeOf(component),
            );
            allocated += 1;
        }

        sortMultiple(component_ids, .{
            component_sizes,
            component_deinits,
            component_added,
            component_destroying,
            data,
        });

        const entities = try allocator.alloc(Entity, preallocated_entities_count);
        errdefer allocator.free(entities);

        var archetype = Archetype{
            .entity_count = 0,
            .component_ids = component_ids,
            .component_sizes = component_sizes,
            .component_deinits = component_deinits,
            .component_added = component_added,
            .component_destroying = component_destroying,
            .data = data,
            .entities = entities,
        };

        if (capacity) |target_capacity| archetype.ensureTotalCapacity(allocator, target_capacity);

        return archetype;
    }

    pub fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        for (self.data, self.component_sizes, self.component_deinits) |buffer, size, deinit_| {
            if (deinit_) |deinit_function| {
                for (0..self.entity_count) |entity_index| {
                    deinit_function(@ptrCast(&buffer[entity_index * size]), allocator);
                }
            }
        }

        allocator.free(self.component_ids);
        allocator.free(self.component_sizes);
        allocator.free(self.component_deinits);
        allocator.free(self.component_added);
        allocator.free(self.component_destroying);
        for (self.data) |value| allocator.free(value);
        allocator.free(self.data);
        allocator.free(self.entities);
    }

    pub fn addEntity(
        self: *Archetype,
        allocator: std.mem.Allocator,
        entity: Entity,
        components: anytype,
    ) !u32 {
        const entity_index = self.entity_count;
        const fields = std.meta.fields(@TypeOf(components));

        if (fields.len != self.component_ids.len) return Error.ComponentMismatch;

        if (self.entity_count == self.entities.len) self.grow(allocator);

        inline for (fields) |field| {
            const idx = self.findComponentIndex(hash(field.type)) orelse {
                return Error.UnknownComponent;
            };

            const value = @field(components, field.name);
            const size = self.component_sizes[idx];
            @memcpy(
                self.data[idx][entity_index * size .. (entity_index + 1) * size],
                std.mem.asBytes(&value),
            );
        }

        self.entities[entity_index] = entity;
        self.entity_count += 1;
        return entity_index;
    }

    pub fn removeEntity(
        self: *Archetype,
        entity_index: u32,
        allocator: std.mem.Allocator,
    ) ?RelocatedEntity {
        if (entity_index >= self.entity_count) return null;

        for (self.data, self.component_sizes, self.component_deinits) |buffer, size, deinit_| {
            if (deinit_) |deinit_function| {
                deinit_function(@ptrCast(&buffer[entity_index * size]), allocator);
            }
        }

        const last_index = self.entity_count - 1;
        self.entity_count -= 1;

        if (entity_index == last_index) return null;

        for (self.data, self.component_sizes) |buffer, size| {
            @memcpy(
                buffer[entity_index * size .. (entity_index + 1) * size],
                buffer[last_index * size .. (last_index + 1) * size],
            );
        }

        const relocated_entity = self.entities[last_index];
        self.entities[entity_index] = relocated_entity;

        return .{ .entity = relocated_entity, .entity_index = entity_index };
    }

    pub fn getComponents(
        self: *Archetype,
        entity_index: u32,
        comptime components: []const type,
    ) !EntityComponents(components) {
        if (entity_index >= self.entity_count) return Error.InvalidEntityIndex;

        var result: EntityComponents(components) = undefined;

        inline for (components, 0..) |component, idx| {
            const component_idx = self.findComponentIndex(hash(component)) orelse {
                return Error.UnknownComponent;
            };

            const size = self.component_sizes[component_idx];
            result[idx] = @ptrCast(@alignCast(&self.data[component_idx][entity_index * size]));
        }

        return result;
    }

    pub fn hasComponents(self: *const Archetype, comptime components: []const type) bool {
        inline for (components) |component| {
            if (self.findComponentIndex(hash(component)) == null) return false;
        }
        return true;
    }

    pub fn ensureTotalCapacity(
        self: *Archetype,
        allocator: std.mem.Allocator,
        capacity: usize,
    ) void {
        if (capacity > self.entities.len) self.growTo(allocator, capacity);
    }

    fn grow(self: *Archetype, allocator: std.mem.Allocator) void {
        self.growTo(allocator, self.entities.len * 2);
    }

    fn growTo(self: *Archetype, allocator: std.mem.Allocator, new_capacity: usize) void {
        self.entities = allocator.realloc(self.entities, new_capacity) catch
            panic("Archetype.growTo: out of memory\n", .{});

        for (self.data, self.component_sizes) |*buffer, size| {
            buffer.* = allocator.realloc(buffer.*, new_capacity * size) catch
                panic("Archetype.growTo: out of memory\n", .{});
        }
    }

    fn findComponentIndex(self: *const Archetype, component_id: u64) ?usize {
        return std.sort.binarySearch(u64, self.component_ids, component_id, struct {
            fn order(context: u64, item: u64) std.math.Order {
                return std.math.order(context, item);
            }
        }.order);
    }
};

pub const RelocatedEntity = struct {
    entity: Entity,
    entity_index: u32,
};

const DeinitFunction = *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void;
fn getDeinitFunctionFor(comptime component: type) ?DeinitFunction {
    if (!std.meta.hasFn(component, "deinit")) return null;

    const params = @typeInfo(@TypeOf(component.deinit)).@"fn".params;

    return switch (params.len) {
        1 => struct {
            fn wrapper(ptr: *anyopaque, _: std.mem.Allocator) void {
                @as(*component, @ptrCast(@alignCast(ptr))).deinit();
            }
        }.wrapper,
        2 => struct {
            fn wrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                @as(*component, @ptrCast(@alignCast(ptr))).deinit(allocator);
            }
        }.wrapper,
        else => @compileError("unsupported deinit signature for " ++ @typeName(component)),
    };
}

fn noOpLifecycleFunctionsFor(comptime component: type) LifecycleFunctions {
    _ = component;
    return .{
        .added = struct {
            fn call(_: *anyopaque, _: std.mem.Allocator, _: Entity) void {}
        }.call,
        .destroying = struct {
            fn call(_: *anyopaque, _: std.mem.Allocator, _: Entity) void {}
        }.call,
    };
}

test "Archetype sorts the components on initialization" {
    const allocator = std.testing.allocator;

    const Type = struct {
        data: [33]u8,
    };

    const Value = struct {
        value: u64,
    };

    const expected_ids: []const u64 = &.{ 9047713391308399252, 15171739973735874036 }; //Value, Type
    const expected_sizes: []const u32 = &.{ @sizeOf(u64), @sizeOf(Type) };

    var archetype = try Archetype.init(allocator, &[_]type{ Value, Type }, null, noOpLifecycleFunctionsFor);
    try std.testing.expectEqualSlices(u64, expected_ids, archetype.component_ids);
    try std.testing.expectEqualSlices(u32, expected_sizes, archetype.component_sizes);
    archetype.deinit(allocator);

    archetype = try Archetype.init(allocator, &[_]type{ Type, Value }, null, noOpLifecycleFunctionsFor);
    try std.testing.expectEqualSlices(u64, expected_ids, archetype.component_ids);
    try std.testing.expectEqualSlices(u32, expected_sizes, archetype.component_sizes);
    archetype.deinit(allocator);
}

test "Archetype allocates as many component arrays as passed component_ids on initialization" {
    const allocator = std.testing.allocator;

    const A = struct { value: u64 };
    const B = struct { value: f32 };
    const C = struct { value: u8 };

    var archetype = try Archetype.init(allocator, &.{ A, B, C }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(3, archetype.data.len);
}

test "Archetype preallocates memory for entities on initialization" {
    const allocator = std.testing.allocator;

    const Type = struct {
        data: [54]u8,
    };

    var archetype = try Archetype.init(allocator, &.{Type}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(preallocated_entities_count * @sizeOf(Type), archetype.data[0].len);
    try std.testing.expectEqual(preallocated_entities_count, archetype.entities.len);
}

test "Can add entities to archetype" {
    const allocator = std.testing.allocator;

    const Type = struct {
        data: u32,
    };

    const Value = struct {
        value: u64,
    };

    var archetype = try Archetype.init(allocator, &.{ Type, Value }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const type_ = Type{ .data = 112 };
    const value_ = Value{ .value = 74 };

    const entity_index = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{ type_, value_ },
    );

    const type_idx = std.mem.indexOfScalar(u64, archetype.component_ids, hash(Type)).?;
    const value_idx = std.mem.indexOfScalar(u64, archetype.component_ids, hash(Value)).?;

    const returned_type = @as(*Type, @ptrCast(@alignCast(archetype.data[type_idx].ptr)));
    const returned_value = @as(*Value, @ptrCast(@alignCast(archetype.data[value_idx].ptr)));

    try std.testing.expectEqual(0, entity_index);
    try std.testing.expectEqual(1, archetype.entity_count);
    try std.testing.expectEqual(type_, returned_type.*);
    try std.testing.expectEqual(value_, returned_value.*);
}

test "addEntity returns Error.ComponentMismatch when the wrong number of components is passed" {
    const allocator = std.testing.allocator;

    const Type = struct { data: u32 };
    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{ Type, Value }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expectError(
        Error.ComponentMismatch,
        archetype.addEntity(allocator, .{ .id = 0, .generation = 0 }, .{Type{ .data = 1 }}),
    );
}

test "addEntity returns Error.UnknownComponent when a passed component type is not in the archetype" {
    const allocator = std.testing.allocator;

    const Type = struct { data: u32 };
    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Type}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expectError(
        Error.UnknownComponent,
        archetype.addEntity(allocator, .{ .id = 0, .generation = 0 }, .{Value{ .value = 1 }}),
    );
}

test "Archetype stores the entity passed to addEntity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const first = Entity{ .id = 3, .generation = 1 };
    const second = Entity{ .id = 7, .generation = 2 };

    const first_index = try archetype.addEntity(allocator, first, .{Value{ .value = 1 }});
    const second_index = try archetype.addEntity(allocator, second, .{Value{ .value = 2 }});

    try std.testing.expectEqual(first, archetype.entities[first_index]);
    try std.testing.expectEqual(second, archetype.entities[second_index]);
}

test "Archetype.deinit deinits resources owned by stored components" {
    const allocator = std.testing.allocator;

    const OwningComponent = struct {
        buffer: []u8,

        fn init(alloc: std.mem.Allocator) !@This() {
            return .{ .buffer = try alloc.alloc(u8, 8) };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.buffer);
        }
    };

    const NonOwningComponent = struct {
        var deinit_calls: usize = 0;

        value: u32,

        pub fn deinit(self: *@This()) void {
            _ = self;
            deinit_calls += 1;
        }
    };

    var archetype = try Archetype.init(allocator, &.{ OwningComponent, NonOwningComponent }, null, noOpLifecycleFunctionsFor);

    const owning = try OwningComponent.init(allocator);
    const non_owning = NonOwningComponent{ .value = 1 };
    _ = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{ owning, non_owning },
    );

    archetype.deinit(allocator);

    try std.testing.expectEqual(1, NonOwningComponent.deinit_calls);
}

test "removeEntity returns null and does not relocate anything when removing the last entity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const first = Entity{ .id = 1, .generation = 0 };
    const second = Entity{ .id = 2, .generation = 0 };

    const first_index = try archetype.addEntity(allocator, first, .{Value{ .value = 10 }});
    const second_index = try archetype.addEntity(allocator, second, .{Value{ .value = 20 }});

    const relocated = archetype.removeEntity(second_index, allocator);

    try std.testing.expectEqual(null, relocated);
    try std.testing.expectEqual(1, archetype.entity_count);
    try std.testing.expectEqual(first, archetype.entities[first_index]);

    const returned_value = @as(*Value, @ptrCast(@alignCast(archetype.data[0].ptr)));
    try std.testing.expectEqual(Value{ .value = 10 }, returned_value.*);
}

test "removeEntity is a no-op when entity_index is out of bounds" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expectEqual(null, archetype.removeEntity(0, allocator));
    try std.testing.expectEqual(0, archetype.entity_count);

    _ = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{Value{ .value = 1 }},
    );

    try std.testing.expectEqual(null, archetype.removeEntity(1, allocator));
    try std.testing.expectEqual(1, archetype.entity_count);
}

test "removeEntity swaps the last entity into the removed slot and returns it as relocated" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const first = Entity{ .id = 1, .generation = 0 };
    const second = Entity{ .id = 2, .generation = 0 };
    const third = Entity{ .id = 3, .generation = 0 };

    _ = try archetype.addEntity(allocator, first, .{Value{ .value = 10 }});
    _ = try archetype.addEntity(allocator, second, .{Value{ .value = 20 }});
    _ = try archetype.addEntity(allocator, third, .{Value{ .value = 30 }});

    const relocated = archetype.removeEntity(0, allocator);

    try std.testing.expectEqual(RelocatedEntity{ .entity = third, .entity_index = 0 }, relocated);
    try std.testing.expectEqual(2, archetype.entity_count);
    try std.testing.expectEqual(third, archetype.entities[0]);

    const returned_value = @as(*Value, @ptrCast(@alignCast(archetype.data[0].ptr)));
    try std.testing.expectEqual(Value{ .value = 30 }, returned_value.*);
}

test "removeEntity deinits resources owned by the removed entity's components" {
    const allocator = std.testing.allocator;

    const OwningComponent = struct {
        buffer: []u8,

        fn init(alloc: std.mem.Allocator) !@This() {
            return .{ .buffer = try alloc.alloc(u8, 8) };
        }

        pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
            alloc.free(self.buffer);
        }
    };

    const NonOwningComponent = struct {
        var deinit_calls: usize = 0;

        value: u32,

        pub fn deinit(self: *@This()) void {
            _ = self;
            deinit_calls += 1;
        }
    };

    var archetype = try Archetype.init(allocator, &.{ OwningComponent, NonOwningComponent }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const owning = try OwningComponent.init(allocator);
    const non_owning = NonOwningComponent{ .value = 1 };
    const entity_index = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{ owning, non_owning },
    );

    _ = archetype.removeEntity(entity_index, allocator);

    try std.testing.expectEqual(1, NonOwningComponent.deinit_calls);
    try std.testing.expectEqual(0, archetype.entity_count);
}

test "Archetype grows its arrays when it runs out of capacity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const count = preallocated_entities_count + 1;

    for (0..count) |index| {
        const entity = Entity{ .id = @intCast(index), .generation = 0 };
        _ = try archetype.addEntity(allocator, entity, .{Value{ .value = @intCast(index) }});
    }

    try std.testing.expectEqual(count, archetype.entity_count);
    try std.testing.expect(archetype.entities.len > preallocated_entities_count);
    try std.testing.expect(archetype.data[0].len >= count * @sizeOf(Value));

    const values = @as([*]Value, @ptrCast(@alignCast(archetype.data[0].ptr)))[0..count];
    for (values, 0..) |value, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index)), value.value);
        try std.testing.expectEqual(@as(u32, @intCast(index)), archetype.entities[index].id);
    }
}

test "getComponents returns pointers to an entity's requested components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var archetype = try Archetype.init(allocator, &.{ Position, Velocity }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const entity_index = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{ Position{ .x = 1, .y = 2 }, Velocity{ .dx = 3, .dy = 4 } },
    );

    const position, const velocity = try archetype.getComponents(
        entity_index,
        &.{ Position, Velocity },
    );

    try std.testing.expectEqual(Position{ .x = 1, .y = 2 }, position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 4 }, velocity.*);

    position.x = 100;

    const reread_position, _ = try archetype.getComponents(entity_index, &.{ Position, Velocity });
    try std.testing.expectEqual(@as(f32, 100), reread_position.x);
}

test "getComponents returns Error.UnknownComponent for a type the archetype does not have" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var archetype = try Archetype.init(allocator, &.{Position}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const entity_index = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{Position{ .x = 1, .y = 2 }},
    );

    try std.testing.expectError(
        Error.UnknownComponent,
        archetype.getComponents(entity_index, &.{Velocity}),
    );
}

test "getComponents returns Error.InvalidEntityIndex when entity_index is out of bounds" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };

    var archetype = try Archetype.init(allocator, &.{Position}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expectError(Error.InvalidEntityIndex, archetype.getComponents(0, &.{Position}));

    _ = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{Position{ .x = 1, .y = 2 }},
    );

    try std.testing.expectError(Error.InvalidEntityIndex, archetype.getComponents(1, &.{Position}));
}

test "getComponents returns the correct entity's data when entity_index is not zero" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var archetype = try Archetype.init(allocator, &.{ Position, Velocity }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    _ = try archetype.addEntity(
        allocator,
        .{ .id = 0, .generation = 0 },
        .{ Position{ .x = 1, .y = 1 }, Velocity{ .dx = 1, .dy = 1 } },
    );
    const second_index = try archetype.addEntity(
        allocator,
        .{ .id = 1, .generation = 0 },
        .{ Position{ .x = 2, .y = 2 }, Velocity{ .dx = 2, .dy = 2 } },
    );
    const third_index = try archetype.addEntity(
        allocator,
        .{ .id = 2, .generation = 0 },
        .{ Position{ .x = 3, .y = 3 }, Velocity{ .dx = 3, .dy = 3 } },
    );

    const second_position, const second_velocity = try archetype.getComponents(
        second_index,
        &.{ Position, Velocity },
    );
    try std.testing.expectEqual(Position{ .x = 2, .y = 2 }, second_position.*);
    try std.testing.expectEqual(Velocity{ .dx = 2, .dy = 2 }, second_velocity.*);

    const third_position, const third_velocity = try archetype.getComponents(
        third_index,
        &.{ Position, Velocity },
    );
    try std.testing.expectEqual(Position{ .x = 3, .y = 3 }, third_position.*);
    try std.testing.expectEqual(Velocity{ .dx = 3, .dy = 3 }, third_velocity.*);
}

test "hasComponents returns true when the archetype has every requested component" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var archetype = try Archetype.init(allocator, &.{ Position, Velocity }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expect(archetype.hasComponents(&.{ Position, Velocity }));
}

test "hasComponents returns true for a subset of the archetype's components" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };
    const Health = struct { value: u32 };

    var archetype = try Archetype.init(allocator, &.{ Position, Velocity, Health }, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expect(archetype.hasComponents(&.{Position}));
}

test "hasComponents returns false when a requested component is missing" {
    const allocator = std.testing.allocator;

    const Position = struct { x: f32, y: f32 };
    const Velocity = struct { dx: f32, dy: f32 };

    var archetype = try Archetype.init(allocator, &.{Position}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expect(!archetype.hasComponents(&.{ Position, Velocity }));
}

test "Archetype.init reserves capacity up front when given one" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, 100, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    try std.testing.expect(archetype.entities.len >= 100);
    try std.testing.expect(archetype.data[0].len >= 100 * @sizeOf(Value));
}

test "ensureTotalCapacity grows the arrays to at least the requested capacity" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    archetype.ensureTotalCapacity(allocator, 100);

    try std.testing.expect(archetype.entities.len >= 100);
    try std.testing.expect(archetype.data[0].len >= 100 * @sizeOf(Value));
}

test "ensureTotalCapacity does nothing when capacity is already sufficient" {
    const allocator = std.testing.allocator;

    const Value = struct { value: u64 };

    var archetype = try Archetype.init(allocator, &.{Value}, null, noOpLifecycleFunctionsFor);
    defer archetype.deinit(allocator);

    const capacity_before = archetype.entities.len;
    archetype.ensureTotalCapacity(allocator, preallocated_entities_count);

    try std.testing.expectEqual(capacity_before, archetype.entities.len);
}
