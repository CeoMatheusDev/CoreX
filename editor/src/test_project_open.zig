//! Black-box tests of the actual Editor bootstrap with a relocatable install.
//! These validate document opening, not a graphical Editor or asset loading.
const std = @import("std");
const app = @import("corex_app");
const options = @import("project_open_options");
const a = std.testing.allocator;
const io = std.testing.io;
const Io = std.Io;
const process = app.child_process;
const exe_name = if (@import("builtin").os.tag == .windows) "CoreXEditor.exe" else "CoreXEditor";
const project_name = "Jogo ação/Example.PROJ";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    executable: []u8,
    project_absolute: []u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(io, "bin");
        try tmp.dir.createDirPath(io, "share/corex");
        try tmp.dir.createDirPath(io, "Jogo ação");
        try Io.Dir.cwd().copyFile(options.editor, tmp.dir, "bin/" ++ exe_name, io, .{});
        try Io.Dir.cwd().copyFile(options.presets, tmp.dir, "share/corex/presets.zon", io, .{});
        try Io.Dir.cwd().copyFile(options.manifest, tmp.dir, "share/corex/distribution.json", io, .{});
        const sample = try std.fs.path.join(a, &.{ options.repository_root, "exemploproject", "Example.proj" });
        defer a.free(sample);
        try Io.Dir.cwd().copyFile(sample, tmp.dir, project_name, io, .{});
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const n = try tmp.dir.realPath(io, &buf);
        const executable = try std.fs.path.join(a, &.{ buf[0..n], "bin", exe_name });
        errdefer a.free(executable);
        const project_absolute = try std.fs.path.join(a, &.{ buf[0..n], project_name });
        return .{ .tmp = tmp, .executable = executable, .project_absolute = project_absolute };
    }
    fn deinit(self: *Fixture) void {
        a.free(self.executable);
        a.free(self.project_absolute);
        self.tmp.cleanup();
    }
    fn run(self: *Fixture, args: []const []const u8) !std.process.RunResult {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.append(a, self.executable);
        try argv.appendSlice(a, args);
        return process.runCommand(a, io, self.executable, argv.items, .{ .dir = self.tmp.dir }, 20_000);
    }
};

fn expectExit(r: std.process.RunResult, code: u8) !void {
    errdefer std.debug.print("Editor exit={f}\nstdout={s}\nstderr={s}\n", .{ r.term, r.stdout, r.stderr });
    try std.testing.expectEqual(std.process.Child.Term{ .exited = code }, r.term);
}
fn contains(text: []const u8, part: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, text, part) != null);
}

test "example opens through positional and explicit project paths without modifying it" {
    var f = try Fixture.init();
    defer f.deinit();
    const original = try f.tmp.dir.readFileAlloc(io, project_name, a, .limited(1024 * 1024));
    defer a.free(original);
    const before = try f.tmp.dir.statFile(io, project_name, .{});
    const cases = [_][]const []const u8{
        &.{ project_name, "--headless", "--validate-only" },
        &.{ "--headless", "--validate-only", f.project_absolute },
        &.{ "--project", project_name, "--headless", "--validate-only" },
    };
    for (cases) |args| {
        const r = try f.run(args);
        defer process.release(a, r);
        try expectExit(r, 0);
        try contains(r.stdout, "\"event\":\"project.document_validated\"");
        try contains(r.stdout, "\"event\":\"editor.validation_complete\"");
        try contains(r.stdout, "\"resources_loaded\":false");
        try std.testing.expectEqualStrings("", r.stderr);
    }
    const after = try f.tmp.dir.readFileAlloc(io, project_name, a, .limited(1024 * 1024));
    defer a.free(after);
    const after_stat = try f.tmp.dir.statFile(io, project_name, .{});
    try std.testing.expectEqualSlices(u8, original, after);
    try std.testing.expectEqual(before.mtime, after_stat.mtime);
}

test "direct editor launch and duplicate project arguments are rejected" {
    var f = try Fixture.init();
    defer f.deinit();
    const missing = try f.run(&.{});
    defer process.release(a, missing);
    try expectExit(missing, 2);
    try contains(missing.stderr, "\"code\":\"MissingProject\"");
    const duplicate = try f.run(&.{ project_name, "--project", f.project_absolute });
    defer process.release(a, duplicate);
    try expectExit(duplicate, 2);
    try contains(duplicate.stderr, "\"code\":\"DuplicateArgument\"");
}

test "positional launch does not pretend the Editor is ready" {
    var f = try Fixture.init();
    defer f.deinit();
    const r = try f.run(&.{f.project_absolute});
    defer process.release(a, r);
    try expectExit(r, 4);
    try contains(r.stderr, "\"event\":\"application.core_unavailable\"");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "editor.ready") == null);
}

test "missing and invalid positional project do not start the Editor" {
    var f = try Fixture.init();
    defer f.deinit();
    const absent = try f.run(&.{ "Missing.proj", "--validate-only" });
    defer process.release(a, absent);
    try expectExit(absent, 3);
    try contains(absent.stderr, "\"event\":\"project.read_failed\"");
    try f.tmp.dir.writeFile(io, .{ .sub_path = project_name, .data = "{invalid" });
    const invalid = try f.run(&.{ project_name, "--validate-only" });
    defer process.release(a, invalid);
    try expectExit(invalid, 3);
    try contains(invalid.stderr, "\"event\":\"project.invalid\"");
}
