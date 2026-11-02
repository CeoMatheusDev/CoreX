//! Allocation-free authoring interaction model; not a scene/GPU implementation.
const std = @import("std");
const app = @import("corex_app");
pub const Domain = app.scope.AuthoringDomain;
pub const Tool = enum { select, translate_3d, rotate_3d, scale_3d, canvas_layout };

pub const State = struct {
    domain: Domain = .scene_3d,
    tool: Tool = .select,

    pub fn setDomain(self: *State, domain: Domain) void {
        if (domain != self.domain) self.* = .{ .domain = domain };
    }

    pub fn activate(self: *State, tool: Tool) error{ToolNotAvailableInDomain}!void {
        const allowed = switch (tool) {
            .select => true,
            .translate_3d, .rotate_3d, .scale_3d => self.domain == .scene_3d,
            .canvas_layout => self.domain == .ui_canvas,
        };
        if (!allowed) return error.ToolNotAvailableInDomain;
        self.tool = tool;
    }
};

test "3D and Canvas transitions reset tools and reject without mutation" {
    var state: State = .{};
    try state.activate(.rotate_3d);
    try std.testing.expectError(error.ToolNotAvailableInDomain, state.activate(.canvas_layout));
    try std.testing.expectEqual(Tool.rotate_3d, state.tool);
    state.setDomain(.ui_canvas);
    try std.testing.expectEqual(Tool.select, state.tool);
    try state.activate(.canvas_layout);
    state.setDomain(.ui_canvas);
    try std.testing.expectEqual(Tool.canvas_layout, state.tool);
    for ([_]Tool{ .translate_3d, .rotate_3d, .scale_3d }) |tool|
        try std.testing.expectError(error.ToolNotAvailableInDomain, state.activate(tool));
    try std.testing.expectEqual(Tool.canvas_layout, state.tool);
    state.setDomain(.scene_3d);
    try std.testing.expectEqual(Tool.select, state.tool);
}
