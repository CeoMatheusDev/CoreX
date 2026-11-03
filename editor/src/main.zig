const std = @import("std");
const app = @import("corex_app");

pub fn main(init: std.process.Init) void {
    const code = app.bootstrap.entry(init, .editor);
    if (code != 0) std.process.exit(code);
}

test {
    std.testing.refAllDecls(app);
    _ = @import("workspace.zig");
    _ = @import("project_preflight.zig");
    _ = @import("project_opening.zig");
    _ = @import("resource_discovery.zig");
}
