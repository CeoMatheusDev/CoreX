const std = @import("std");
const Engine = @import("core/engine.zig").Engine;
const ProjectLoader = @import("project/loader.zig").ProjectLoader;
const World = @import("ecs/ecs.zig").World;
const Renderer = @import("graphics/renderer/render.zig").Renderer;
const JobSystem = @import("jobs/job_system.zig").JobSystem;
const EventBus = @import("events/event.zig").EventBus;
const Event = @import("events/event.zig").Event;
const AudioEngine = @import("audio/audio.zig").AudioEngine;
const AnimationSystem = @import("animation/animation.zig").AnimationSystem;
const Scene = @import("scene/scene.zig").Scene;
const Serializer = @import("serialization/serializer.zig").Serializer;
const AssetPipeline = @import("assets/asset.zig").AssetPipeline;
const Profiler = @import("profiler/profiler.zig").Profiler;

fn countEvent(context: *anyopaque, _: Event) void {
    const count: *usize = @ptrCast(@alignCast(context));
    count.* += 1;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    var engine = try Engine.init(allocator);
    defer {
        // Limpeza básica
    }

    var loader = ProjectLoader.init(allocator);
    const config = try loader.load("test_project/TestProject.proj");

    std.debug.print("CoreX Engine iniciado. Projeto: {s} (versão {s})\n", .{ config.project.name, config.project.version });
    std.debug.print("Perfil gráfico: {s} | API: {s} | Resolução: {d}x{d}\n", .{ config.graphics.quality, config.graphics.api, config.graphics.resolution.width, config.graphics.resolution.height });
    std.debug.print("Física timestep: {d}\n", .{config.physics.fixed_timestep});
    std.debug.print("Cena inicial: {s}\n", .{config.scenes.startup});

    engine.start();
    engine.tick();

    // Demonstração ECS — evolução incremental
    var world = World.init(allocator);
    const e = world.createEntity();
    std.debug.print("ECS ativo — entidade {d}\n", .{e});

    // Demonstração Renderer — evolução incremental
    var renderer = try Renderer.init(allocator);
    renderer.beginPass("main");
    renderer.endPass();
    std.debug.print("Renderer ativo — pass 'main' concluída\n", .{});

    // Demonstração Job System — evolução incremental
    var jsys = try JobSystem.init(allocator);
    defer jsys.deinit();
    std.debug.print("Job System ativo — capacidade: {d}\n", .{jsys.capacity});

    var bus = try EventBus.init(allocator, 8);
    defer bus.deinit() catch unreachable;
    var received: usize = 0;
    _ = try bus.subscribe(42, countEvent, &received);
    try bus.publish(.{ .id = 42, .payload = "corex_event" });
    std.debug.print("Event Bus síncrono — entregas: {d}\n", .{received});

    var aud = try AudioEngine.init(allocator);
    defer aud.deinit();
    aud.play("startup_sound.wav");
    std.debug.print("Audio System ativo\n", .{});

    var anim_sys = AnimationSystem.init(allocator);
    anim_sys.play(.{ .name = "startup", .duration_ms = 500.0 });
    std.debug.print("Animation System ativo\n", .{});

    const scene = Scene{ .name = "start", .entities = &[_]u32{1} };
    std.debug.print("Scene ativo — {s} com {d} entidades\n", .{ scene.name, scene.entities.len });

    const ser = Serializer.init(allocator);
    _ = ser;
    std.debug.print("Serialization ativo\n", .{});

    var asset = AssetPipeline.init(allocator);
    const a = try asset.load("data/config.json");
    std.debug.print("Asset Pipeline ativo — {s} carregado\n", .{a.path});

    var prof = Profiler.init();
    prof.start();
    _ = prof.stop();
    std.debug.print("Profiler ativo\n", .{});

    engine.stop();
}
