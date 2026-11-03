const std = @import("std");
const app = @import("corex_app");
const run_mode = @import("run_mode.zig");

/// The application supplies the execution backend. `shared` never links Core,
/// so without this bridge every execution request stays `core_unavailable`.
fn runHeadless(_: ?*anyopaque, request: app.bootstrap.RunRequest) anyerror!app.bootstrap.RunReport {
    const report = try run_mode.run(.{ .frames = request.frames });
    return .{
        .frames = report.frames,
        .steps = report.steps,
        .ticks = report.ticks,
        .input_ticks = report.input_ticks,
        .phase_remainder = report.phase_remainder,
    };
}

pub fn main(init: std.process.Init) void {
    const code = app.bootstrap.entryWith(init, .runtime, .{ .run = runHeadless });
    if (code != 0) std.process.exit(code);
}

test {
    std.testing.refAllDecls(app);
    _ = @import("timing.zig");
    _ = @import("tick_input.zig");
    _ = @import("run_mode.zig");
}
