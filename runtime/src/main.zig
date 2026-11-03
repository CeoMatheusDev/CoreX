const std = @import("std");
const app = @import("corex_app");
const run_mode = @import("run_mode.zig");

/// The application supplies the execution backend. `shared` never links Core,
/// so without this bridge every execution request stays `core_unavailable`.
const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
};

fn runHeadless(context: ?*anyopaque, request: app.bootstrap.RunRequest) anyerror!app.bootstrap.RunReport {
    const state: *Context = @ptrCast(@alignCast(context.?));
    const report = try run_mode.run(state.gpa, .{ .frames = request.frames, .scene_path = request.scene_path, .io = state.io });
    return .{
        .frames = report.frames,
        .steps = report.steps,
        .ticks = report.ticks,
        .input_ticks = report.input_ticks,
        .phase_remainder = report.phase_remainder,
        .entities_alive = report.entities_alive,
        .state_checksum = report.state_checksum,
    };
}

pub fn main(init: std.process.Init) void {
    var context: Context = .{ .gpa = init.gpa, .io = init.io };
    const code = app.bootstrap.entryWith(init, .runtime, .{
        .context = @ptrCast(&context),
        .run = runHeadless,
    });
    if (code != 0) std.process.exit(code);
}

test {
    std.testing.refAllDecls(app);
    _ = @import("timing.zig");
    _ = @import("tick_input.zig");
    _ = @import("headless_app.zig");
    _ = @import("run_mode.zig");
}
