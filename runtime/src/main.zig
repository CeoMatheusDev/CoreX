const std = @import("std");
const app = @import("corex_app");

pub fn main(init: std.process.Init) void {
    const code = app.bootstrap.entry(init, .runtime);
    if (code != 0) std.process.exit(code);
}

test {
    std.testing.refAllDecls(app);
}
