//! Deterministic headless execution harness for the Runtime.
//!
//! This is the product's first real executor: it drives the Core lifecycle and
//! subsystem registry with the existing fixed-step scheduler, input tick
//! buffer and a declared smoke Scene. It deliberately creates no window, no GPU
//! device, no swapchain and no asset database, and it presents no frames. The
//! clock is virtual: every frame credits a fixed interval instead of reading
//! wall time, so runs are reproducible. Nothing here may be described as Play,
//! as graphics or as proof that a renderer exists.
const std = @import("std");
const core = @import("corex_core");
const scene = @import("corex_scene");
const timing = @import("timing.zig");
const tick_input = @import("tick_input.zig");
const headless_app = @import("headless_app.zig");

/// Simulation rate accepted by the project schema.
pub const tick_hz: u32 = 60;

/// Integer frame interval: 1/60 s rounded up. The scheduler accumulates the
/// excess (20 phase units per frame) instead of dropping it, so one frame
/// produces exactly one tick across the whole supported range.
pub const frame_ns: u64 = 16_666_667;

pub const max_frames: u32 = 1_000_000;

/// Catch-up bound: one frame never runs more than this many ticks, so a hitch
/// cannot turn into an unbounded spiral.
pub const max_steps_per_frame: u32 = 8;

pub const Request = struct {
    frames: u32,
    /// Optional content-scene file path. When set, the scene is loaded from
    /// this file instead of the embedded smoke scene.
    scene_path: ?[]const u8 = null,
    /// I/O interface for file reads (scene loading). Required when scene_path
    /// is set.
    io: ?std.Io = null,
};

pub const Report = struct {
    frames: u32,
    steps: u64,
    ticks: u64,
    input_ticks: u64,
    phase_remainder: u64,
    entities_alive: u32,
    state_checksum: u64,
};

/// Fixed-step driver: a thin policy layer over `timing.Scheduler`. It owns how
/// much virtual time a frame credits and how many ticks a frame may catch up.
const Driver = struct {
    scheduler: timing.Scheduler,
    budget: u32,

    fn init(hz: u32, budget: u32) error{ InvalidTickRate, InvalidStepBudget }!Driver {
        if (budget == 0) return error.InvalidStepBudget;
        return .{ .scheduler = try timing.Scheduler.init(hz), .budget = budget };
    }

    fn addFrame(self: *Driver) error{ ElapsedOverflow, TickInProgress }!void {
        try self.scheduler.addElapsed(frame_ns);
    }

    fn dueSteps(self: *const Driver) u32 {
        return self.scheduler.pending(self.budget);
    }

    fn commitStep(self: *Driver) error{ NoTickDue, TickCounterOverflow, TickInProgress }!void {
        try self.scheduler.commitTick();
    }

    fn tickCount(self: *const Driver) u64 {
        return self.scheduler.completed_ticks;
    }

    fn remainder(self: *const Driver) u64 {
        return @intCast(@min(self.scheduler.phase, std.math.maxInt(u64)));
    }
};

/// Owns the input tick buffer. In headless mode no input is staged; the buffer
/// still advances one tick per step, which proves input and simulation ticks
/// stay aligned. Storage lives inside this value, so the value must stay in a
/// stable location while the registry holds its pointer.
const Input = struct {
    const Entry = tick_input.Buffer(u32).Entry;
    const capacity = 4;

    storage: [capacity]Entry = undefined,
    buffer: tick_input.Buffer(u32) = undefined,
    committed: u64 = 0,

    pub fn start(self: *Input) anyerror!void {
        if (self.committed != 0) return error.ReusedSubsystem;
        self.buffer = tick_input.Buffer(u32).init(&self.storage, 0);
    }

    pub fn step(self: *Input, descriptor: core.subsystem.Step) anyerror!void {
        const entries = try self.buffer.beginTick(descriptor.index);
        if (entries.len != 0) {
            self.buffer.abortTick() catch {};
            return error.UnexpectedHeadlessInput;
        }
        try self.buffer.commitTick();
        self.committed += 1;
    }

    pub fn stop(self: *Input) void {
        _ = self;
    }
};

/// Verifies the step contract the loop promises: contiguous zero-based indices
/// and one constant duration. It turns silent loop regressions into errors.
const Ledger = struct {
    steps: u64 = 0,
    step_ns: u64 = 0,

    pub fn start(self: *Ledger) anyerror!void {
        if (self.steps != 0) return error.ReusedSubsystem;
        self.step_ns = 0;
    }

    pub fn step(self: *Ledger, descriptor: core.subsystem.Step) anyerror!void {
        if (descriptor.dt_ns == 0) return error.ZeroStepDuration;
        if (descriptor.index != self.steps) return error.StepIndexDiscontinuity;
        if (self.steps == 0) {
            self.step_ns = descriptor.dt_ns;
        } else if (descriptor.dt_ns != self.step_ns) {
            return error.StepDurationChanged;
        }
        self.steps += 1;
    }

    pub fn stop(self: *Ledger) void {
        _ = self;
    }
};

/// Runs `request.frames` virtual frames. The Scene is a real Core subsystem
/// between input and the ledger. Its entities/components are built explicitly
/// after `registry.start()`, then every tick runs the scene systems. The
/// registry is always torn down, including on failure. `error.InvalidFrameCount`
/// is returned before any work; every other error comes from a subsystem and is
/// propagated unchanged.
pub fn run(allocator: std.mem.Allocator, request: Request) anyerror!Report {
    if (request.frames == 0 or request.frames > max_frames) return error.InvalidFrameCount;
    var driver = try Driver.init(tick_hz, max_steps_per_frame);
    var input: Input = .{};
    var ledger: Ledger = .{};

    var smoke = try headless_app.init(allocator);
    defer smoke.deinit();
    try headless_app.installSystems(&smoke);

    var registry = core.subsystem.Registry(3){};
    try registry.register(core.subsystem.Subsystem.adopt(Input, "runtime.input", &input));
    try registry.register(core.subsystem.Subsystem.adopt(headless_app.Scene, "runtime.scene", &smoke));
    try registry.register(core.subsystem.Subsystem.adopt(Ledger, "runtime.ledger", &ledger));
    try registry.start();
    defer registry.stop() catch {};

    // Explicit builder: the scene is running, but its World belongs to it.
    if (request.scene_path) |scene_path| {
        // Load content scene from file instead of the embedded smoke scene.
        const io = request.io orelse return error.MissingIo;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, scene_path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(bytes);
        var file = try scene.content_format.parse(allocator, bytes);
        defer scene.content_format.deinit(allocator, &file);
        try scene.content_loader.load(headless_app.Stores, smoke.world(), &file);
    } else {
        try headless_app.populate(&smoke);
    }

    var steps: u64 = 0;
    var frames: u32 = 0;
    while (frames < request.frames) : (frames += 1) {
        try driver.addFrame();
        const due = driver.dueSteps();
        var index: u32 = 0;
        while (index < due) : (index += 1) {
            try registry.step(.{ .index = steps, .dt_ns = frame_ns });
            try driver.commitStep();
            steps += 1;
        }
    }

    const ticks = driver.tickCount();
    // Independent counters must agree before anything is reported.
    if (ticks != steps or input.committed != steps or ledger.steps != steps) return error.AccountingMismatch;
    return .{
        .frames = frames,
        .steps = steps,
        .ticks = ticks,
        .input_ticks = input.committed,
        .phase_remainder = driver.remainder(),
        .entities_alive = headless_app.entitiesAlive(&smoke),
        .state_checksum = headless_app.stateChecksum(&smoke),
    };
}

const testing = std.testing;

test "one virtual frame produces exactly one fixed step" {
    const report = try run(testing.allocator, .{ .frames = 1 });
    try testing.expectEqual(@as(u32, 1), report.frames);
    try testing.expectEqual(@as(u64, 1), report.steps);
    try testing.expectEqual(@as(u64, 1), report.ticks);
    try testing.expectEqual(@as(u64, 1), report.input_ticks);
    // 16_666_667 ns at 60 Hz leaves 20 phase units, not a lost fraction.
    try testing.expectEqual(@as(u64, 20), report.phase_remainder);
    try testing.expectEqual(headless_app.initial_entities, report.entities_alive);
    try testing.expect(report.state_checksum != 0);
}

test "a long run keeps every counter aligned and is deterministic" {
    const first = try run(testing.allocator, .{ .frames = 600 });
    const second = try run(testing.allocator, .{ .frames = 600 });
    try testing.expectEqual(@as(u32, 600), first.frames);
    try testing.expectEqual(@as(u64, 600), first.steps);
    try testing.expectEqual(@as(u64, 600), first.ticks);
    try testing.expectEqual(@as(u64, 600), first.input_ticks);
    try testing.expectEqual(@as(u64, 12_000), first.phase_remainder);
    try testing.expectEqualDeep(first, second);
}

test "smoke scene state is deterministic and changes with the tick count" {
    const first = try run(testing.allocator, .{ .frames = 120 });
    const second = try run(testing.allocator, .{ .frames = 120 });
    const third = try run(testing.allocator, .{ .frames = 121 });
    try testing.expectEqual(headless_app.initial_entities, first.entities_alive);
    try testing.expectEqualDeep(first, second);
    try testing.expect(third.state_checksum != first.state_checksum);
    try testing.expectEqual(first.entities_alive, third.entities_alive);
}

test "unsupported frame counts are rejected before any work" {
    try testing.expectError(error.InvalidFrameCount, run(testing.allocator, .{ .frames = 0 }));
    try testing.expectError(error.InvalidFrameCount, run(testing.allocator, .{ .frames = max_frames + 1 }));
}

test "content scene loads from file and runs deterministically" {
    // Write a temporary scene file.
    const test_io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const scene_json = "{\"entity_capacity\": 8, \"entities\": [{\"name\": \"c0\", \"components\": [{\"kind\": \"position\", \"x\": 1, \"y\": 2}, {\"kind\": \"velocity\", \"x\": 1, \"y\": 1}, {\"kind\": \"age\", \"ticks\": 0}]}, {\"name\": \"c1\", \"components\": [{\"kind\": \"position\", \"x\": 5, \"y\": 6}, {\"kind\": \"velocity\", \"x\": -1, \"y\": 1}, {\"kind\": \"age\", \"ticks\": 0}]}]}";
    try tmp.dir.writeFile(test_io, .{ .sub_path = "test.scene", .data = scene_json });
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try tmp.dir.realPath(test_io, &buf);
    const path = try std.fs.path.join(testing.allocator, &.{ buf[0..n], "test.scene" });
    defer testing.allocator.free(path);

    const first = try run(testing.allocator, .{ .frames = 10, .scene_path = path, .io = test_io });
    const second = try run(testing.allocator, .{ .frames = 10, .scene_path = path, .io = test_io });
    try testing.expectEqual(@as(u32, 2), first.entities_alive);
    try testing.expectEqualDeep(first, second);
    try testing.expect(first.state_checksum != 0);

    // A different frame count produces a different checksum.
    const third = try run(testing.allocator, .{ .frames = 11, .scene_path = path, .io = test_io });
    try testing.expect(third.state_checksum != first.state_checksum);
}

test "missing scene file fails cleanly" {
    try testing.expectError(error.FileNotFound, run(testing.allocator, .{ .frames = 1, .scene_path = "/nonexistent/scene.json", .io = testing.io }));
}

test "the step budget caps catch-up without discarding the backlog" {
    var driver = try Driver.init(tick_hz, 2);
    try testing.expectError(error.InvalidStepBudget, Driver.init(tick_hz, 0));
    // 100 ms at 60 Hz is 6 whole ticks; the budget allows only 2 per frame.
    try driver.scheduler.addElapsed(100 * std.time.ns_per_ms);
    try testing.expectEqual(@as(u32, 2), driver.dueSteps());
    try driver.commitStep();
    try driver.commitStep();
    // Four of the six overdue ticks remain in the accumulator.
    try testing.expectEqual(@as(u64, 4_000_000_000), driver.remainder());
    try testing.expectEqual(@as(u32, 2), driver.dueSteps());
}

test "the ledger rejects discontinuous indices, changing durations and reuse" {
    var ledger: Ledger = .{};
    try ledger.start();
    try testing.expectError(error.ZeroStepDuration, ledger.step(.{ .index = 0, .dt_ns = 0 }));
    try ledger.step(.{ .index = 0, .dt_ns = 16 });
    try testing.expectError(error.StepIndexDiscontinuity, ledger.step(.{ .index = 2, .dt_ns = 16 }));
    try testing.expectError(error.StepDurationChanged, ledger.step(.{ .index = 1, .dt_ns = 17 }));
    try ledger.step(.{ .index = 1, .dt_ns = 16 });
    try testing.expectEqual(@as(u64, 2), ledger.steps);
    try testing.expectError(error.ReusedSubsystem, ledger.start());
}

test "headless input stays aligned and refuses staged input" {
    var input: Input = .{};
    try input.start();
    try testing.expectEqual(@as(u64, 0), input.committed);
    try input.step(.{ .index = 0, .dt_ns = frame_ns });
    try testing.expectEqual(@as(u64, 1), input.committed);
    try testing.expectError(error.UnexpectedTick, input.step(.{ .index = 5, .dt_ns = frame_ns }));
    try testing.expectEqual(@as(u64, 1), input.committed);
    try testing.expectError(error.ReusedSubsystem, input.start());
}

test "scene systems run for many ticks with no allocation and reach a real final state" {
    var counter = scene.testing_allocator.CountingAllocator{ .backing = testing.allocator };
    var smoke = try headless_app.init(counter.allocator());
    defer smoke.deinit();
    try headless_app.installSystems(&smoke);
    try smoke.start();
    defer smoke.stop();
    try headless_app.populate(&smoke);

    counter.resetCounters();
    var index: u64 = 0;
    while (index < 100) : (index += 1) {
        try smoke.update(.{ .index = index, .dt_ns = frame_ns });
    }
    try testing.expectEqual(@as(usize, 0), counter.allocations);

    const world = smoke.worldConst();
    var alive: u32 = 0;
    var entity_index: u32 = 0;
    while (entity_index < world.highWater()) : (entity_index += 1) {
        const entity = world.entityAt(entity_index) orelse continue;
        alive += 1;
        const age = world.getConst(headless_app.Age, entity).?;
        try testing.expectEqual(@as(u64, 100), age.ticks);
        const position = world.getConst(headless_app.Position, entity).?;
        const velocity = world.getConst(headless_app.Velocity, entity).?;
        try testing.expectEqual(@as(i64, @as(i64, entity_index) * 10) + velocity.x * 100, position.x);
        try testing.expectEqual(@as(i64, @as(i64, entity_index) * 20) + velocity.y * 100, position.y);
    }
    try testing.expectEqual(headless_app.initial_entities, alive);
}
