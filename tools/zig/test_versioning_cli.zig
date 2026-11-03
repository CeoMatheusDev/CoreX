//! Black-box tests for the native version/release CLI using isolated VERSION files.
const std = @import("std");
const process = @import("corex_app").child_process;
const options = @import("versioning_cli_options");
const Io = std.Io;
const a = std.testing.allocator;
const io = std.testing.io;

const Fixture = struct {
    tmp: std.testing.TmpDir,
    dir: Io.Dir,
    executable: [:0]u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var dir = try tmp.dir.createDirPathOpen(io, "version workspace", .{});
        errdefer dir.close(io);
        try dir.createDirPath(io, "shared/fixtures");
        var repository = try Io.Dir.cwd().openDir(io, options.repository_root, .{});
        defer repository.close(io);
        const presets = try repository.readFileAlloc(io, "shared/fixtures/presets.zon", a, .limited(64 * 1024));
        defer a.free(presets);
        try dir.writeFile(io, .{ .sub_path = "shared/fixtures/presets.zon", .data = presets });
        const executable = try Io.Dir.cwd().realPathFileAlloc(io, options.version_tool, a);
        errdefer a.free(executable);
        return .{ .tmp = tmp, .dir = dir, .executable = executable };
    }

    fn deinit(self: *Fixture) void {
        a.free(self.executable);
        self.dir.close(io);
        self.tmp.cleanup();
    }

    fn setVersion(self: *Fixture, text: []const u8) !void {
        try self.dir.writeFile(io, .{ .sub_path = "VERSION", .data = text });
    }

    fn readVersion(self: *Fixture) ![]u8 {
        return self.dir.readFileAlloc(io, "VERSION", a, .limited(128));
    }

    fn run(self: *Fixture, args: []const []const u8) !process.Result {
        const argv = try a.alloc([]const u8, args.len + 1);
        defer a.free(argv);
        argv[0] = self.executable;
        @memcpy(argv[1..], args);
        return process.runCommand(a, io, self.executable, argv, .{ .dir = self.dir }, 20_000);
    }
};

test "version and compare commands operate on strict product identities" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.setVersion("0.1.0a1\n");
    const version = try fixture.run(&.{"version"});
    defer process.release(a, version);
    try std.testing.expect(version.term.success());
    try std.testing.expectEqualStrings("0.1.0a1\n", version.stdout);

    const compare = try fixture.run(&.{ "compare", "0.1.0a1", "0.1.0b1" });
    defer process.release(a, compare);
    try std.testing.expect(compare.term.success());
    try std.testing.expectEqualStrings("less\n", compare.stdout);
}

test "dry-run validates a transition without writing VERSION" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.setVersion("0.1.0a1\n");
    const result = try fixture.run(&.{ "bump", "beta", "--dry-run" });
    defer process.release(a, result);
    try std.testing.expect(result.term.success());
    try std.testing.expectEqualStrings("0.1.0a1 -> 0.1.0b1 (dry-run)\n", result.stdout);
    const version = try fixture.readVersion();
    defer a.free(version);
    try std.testing.expectEqualStrings("0.1.0a1\n", version);
}

test "release check validates the embedded identity, manifest and table without writing" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.setVersion("0.1.0b1\n");
    const stale = try fixture.run(&.{ "release", "check" });
    defer process.release(a, stale);
    try std.testing.expect(!stale.term.success());
    const stale_version = try fixture.readVersion();
    defer a.free(stale_version);
    try std.testing.expectEqualStrings("0.1.0b1\n", stale_version);

    try fixture.setVersion("0.1.0a1\n");
    const result = try fixture.run(&.{ "release", "check" });
    defer process.release(a, result);
    try std.testing.expect(result.term.success());
    try std.testing.expectEqualStrings("Release checks passed; no Git tag or release was created.\n", result.stdout);
    const version = try fixture.readVersion();
    defer a.free(version);
    try std.testing.expectEqualStrings("0.1.0a1\n", version);
}

test "real bump writes only VERSION and invalid transition leaves it unchanged" {
    var fixture = try Fixture.init();
    defer fixture.deinit();
    try fixture.setVersion("0.1.0a1\n");
    const invalid = try fixture.run(&.{ "bump", "final" });
    defer process.release(a, invalid);
    try std.testing.expect(!invalid.term.success());
    const unchanged = try fixture.readVersion();
    defer a.free(unchanged);
    try std.testing.expectEqualStrings("0.1.0a1\n", unchanged);

    const result = try fixture.run(&.{ "bump", "beta" });
    defer process.release(a, result);
    try std.testing.expect(result.term.success());
    try std.testing.expectEqualStrings("0.1.0a1 -> 0.1.0b1\n", result.stdout);
    const updated = try fixture.readVersion();
    defer a.free(updated);
    try std.testing.expectEqualStrings("0.1.0b1\n", updated);
}
