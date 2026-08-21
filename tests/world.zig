const std = @import("std");

const ecs = @import("ecs");

const World = ecs.World;
const Entity = ecs.Entity;
const Query = ecs.Query;
const Entities = ecs.Entities;
const Resources = ecs.Resources;
const Systems = ecs.Systems;
const Observers = ecs.Observers;
const OneShots = ecs.OneShots;
const Resource = ecs.Resource;
const Event = ecs.Event;
const EventId = ecs.EventId;
const Error = ecs.Error;
const componentId = ecs.componentId;
const component_events = ecs.events.component;
const resource_events = ecs.events.resource;
const ComponentAdded = ecs.events.ComponentAdded;
const ComponentDestroying = ecs.events.ComponentDestroying;
const ResourceAdded = ecs.events.ResourceAdded;
const ResourceDestroying = ecs.events.ResourceDestroying;

test "integration: a plugin's build can register an observer through Entities" {
    const Damage = struct { amount: u32 };
    const Plugin = struct {
        total: u32 = 0,

        pub fn build(self: *@This(), observers: Observers, allocator: std.mem.Allocator) void {
            observers.add(allocator, EventId.from(Damage), onDamage, self);
        }

        fn onDamage(self: *@This(), event: Event(Damage)) void {
            self.total += event.value.amount;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit(std.testing.allocator);

    world.addOwnedPlugin(std.testing.allocator, Plugin{});
    world.runSystems(std.testing.allocator);
    Observers.fromWorld(std.testing.allocator, &world).dispatchOwnedEvent(std.testing.allocator, Damage{ .amount = 5 });

    const entry = world.observers.observers.values()[0].items[0];
    const plugin: *Plugin = @ptrCast(@alignCast(entry.plugin_function.plugin));
    try std.testing.expectEqual(5, plugin.total);
}
