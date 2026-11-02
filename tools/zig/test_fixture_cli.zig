//! Black-box tests of the compiled fixture checker against isolated copies of
//! the real repository inputs. The Python differential suite remains separate.
const std = @import("std");
const process = @import("corex_app").child_process;
const options = @import("fixture_cli_options");
const Io = std.Io;
const a = std.testing.allocator;
const io = std.testing.io;
const paths = [_][]const u8{
    "docs/examples/EmptyGame.proj",        "shared/fixtures/EmptyGame.proj",
    "docs/examples/EmptyGameV2.proj",      "shared/fixtures/EmptyGameV2.proj",
    "docs/examples/presets.zon",           "shared/fixtures/presets.zon",
    "docs/schemas/project-v1.schema.json", "docs/schemas/project-v2.schema.json",
    "shared/fixtures/distribution.json",
};
const schema2_head = "{\"properties\":{\"schema_version\":{\"const\":2},\"engine\":{\"properties\":{\"graphics_backend\":{\"enum\":";
const schema2_tail = "}}}}}";

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: Io.Dir,
    unrelated: Io.Dir,
    root_path: []u8,
    checker: [:0]u8,

    fn init() !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var root = try tmp.dir.createDirPathOpen(io, "Projeto ação", .{});
        errdefer root.close(io);
        var source = try Io.Dir.cwd().openDir(io, options.repository_root, .{});
        defer source.close(io);
        for (paths) |path| {
            const content = try source.readFileAlloc(io, path, a, .limited(4 * 1024 * 1024));
            defer a.free(content);
            if (std.fs.path.dirname(path)) |parent| try root.createDirPath(io, parent);
            try root.writeFile(io, .{ .sub_path = path, .data = content });
        }
        var unrelated = try root.createDirPathOpen(io, "unrelated cwd", .{});
        errdefer unrelated.close(io);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path_len = try root.realPath(io, &path_buf);
        const root_path = try a.dupe(u8, path_buf[0..path_len]);
        errdefer a.free(root_path);
        const checker = try Io.Dir.cwd().realPathFileAlloc(io, options.checker, a);
        return .{ .tmp = tmp, .root = root, .unrelated = unrelated, .root_path = root_path, .checker = checker };
    }
    fn deinit(self: *Fixture) void {
        a.free(self.checker);
        a.free(self.root_path);
        self.unrelated.close(io);
        self.root.close(io);
        self.tmp.cleanup();
    }
    fn write(self: *Fixture, path: []const u8, data: []const u8) !void {
        try self.root.writeFile(io, .{ .sub_path = path, .data = data });
    }
    fn pair(self: *Fixture, i: usize, data: []const u8) !void {
        try self.write(paths[i], data);
        try self.write(paths[i + 1], data);
    }
    fn call(self: *Fixture, args: []const []const u8, cwd: Io.Dir) !std.process.RunResult {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.append(a, self.checker);
        try argv.appendSlice(a, args);
        return process.runCommand(a, io, self.checker, argv.items, .{ .dir = cwd }, 20_000);
    }
    fn expect(self: *Fixture, wanted_error: ?[]const u8, contexts: []const []const u8) !void {
        const result = try self.call(&.{ "--root", self.root_path }, self.unrelated);
        defer process.release(a, result);
        errdefer std.debug.print("fixture CLI failed expectation: term={f}\nstdout={s}\nstderr={s}\n", .{ result.term, result.stdout, result.stderr });
        try std.testing.expectEqual(std.process.Child.Term{ .exited = if (wanted_error == null) 0 else 1 }, result.term);
        if (wanted_error) |error_name| {
            try std.testing.expect(std.mem.indexOf(u8, result.stderr, error_name) != null);
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, "OK:") == null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, result.stdout, "OK:") != null);
        }
        for (contexts) |context| try std.testing.expect(std.mem.indexOf(u8, result.stderr, context) != null);
    }
};

fn setSchema2(f: *Fixture, backends: []const u8) !void {
    const schema = try std.mem.concat(a, u8, &.{ schema2_head, backends, schema2_tail });
    defer a.free(schema);
    try f.write(paths[7], schema);
}

test "valid actual inputs and CLI argument behavior" {
    var f = try Fixture.init();
    defer f.deinit();
    try f.expect(null, &.{});
    const result = try f.call(&.{}, f.root);
    defer process.release(a, result);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 0 }, result.term);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "OK:") != null);
    const cases = [_]struct { args: []const []const u8, code: u8 }{
        .{ .args = &.{"--help"}, .code = 0 },
        .{ .args = &.{"--root"}, .code = 1 },
        .{ .args = &.{ "--root", "" }, .code = 1 },
        .{ .args = &.{ "--help", "extra" }, .code = 1 },
        .{ .args = &.{"--unknown"}, .code = 1 },
        .{ .args = &.{ "--root", "missing-root" }, .code = 1 },
    };
    for (cases) |case| {
        const r = try f.call(case.args, f.root);
        defer process.release(a, r);
        try std.testing.expectEqual(std.process.Child.Term{ .exited = case.code }, r.term);
        if (case.code == 0) try std.testing.expect(std.mem.indexOf(u8, r.stdout, "Usage: corex-check-fixtures") != null);
    }
}

test "all documented pairs report mismatch and both paths" {
    const errors = [_][]const u8{ "V1FixtureMismatch", "V2FixtureMismatch", "PresetsFixtureMismatch" };
    for (errors, 0..) |error_name, n| {
        var f = try Fixture.init();
        defer f.deinit();
        const i = n * 2;
        try f.write(paths[i], "different");
        try f.expect(error_name, &.{ paths[i], paths[i + 1] });
    }
}

test "every input is required" {
    for (paths) |path| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.root.deleteFile(io, path);
        try f.expect("FileNotFound", &.{path});
    }
}

test "malformed JSON is rejected in every parsed file" {
    for ([_]usize{ 1, 3, 6, 7, 8 }) |i| {
        var f = try Fixture.init();
        defer f.deinit();
        if (i == 1 or i == 3) try f.pair(i - 1, "{") else try f.write(paths[i], "{");
        try f.expect("UnexpectedEndOfInput", &.{paths[i]});
    }
}

test "schema and project versions change independently" {
    for ([_]usize{ 0, 2 }) |i| {
        for ([_]bool{ false, true }) |change_schema| {
            var f = try Fixture.init();
            defer f.deinit();
            if (change_schema) {
                if (i == 0) {
                    try f.write(paths[6], "{\"properties\":{\"schema_version\":{\"const\":99}}}");
                } else {
                    try f.write(paths[7], "{\"properties\":{\"schema_version\":{\"const\":99}}}");
                }
            } else try f.pair(i, "{\"schema_version\":99}");
            const schema = if (i == 0) paths[6] else paths[7];
            try f.expect("SchemaVersionMismatch", &.{ schema, paths[i + 1] });
        }
    }
}

test "backend order, length, types and presets hash" {
    for ([_][]const u8{
        "[\"opengl\",\"vulkan\",\"d3d11\",\"d3d12\"]",
        "[\"vulkan\",\"opengl\",\"d3d11\"]",
        "[\"vulkan\",\"opengl\",\"d3d11\",\"d3d12\",\"metal\"]",
        "[\"vulkan\",\"opengl\",\"d3d11\",12]",
        "null",
        "\"vulkan\"",
    }, 0..) |backends, i| {
        var f = try Fixture.init();
        defer f.deinit();
        try setSchema2(&f, backends);
        try f.expect(if (i < 4) "BackendMismatch" else "InvalidContractShape", &.{paths[7]});
    }
    var f = try Fixture.init();
    defer f.deinit();
    try f.pair(4, "modified presets");
    try f.expect("PresetsHashMismatch", &.{ paths[8], paths[5] });
}

test "missing and wrong-shaped fields fail" {
    for ([_]usize{ 6, 7, 8 }) |i| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.write(paths[i], "{}");
        try f.expect("InvalidContractShape", &.{paths[i]});
    }
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(paths[8], "{\"presets_sha256\":123}");
    try f.expect("InvalidContractShape", &.{paths[8]});
}

test "duplicate and escaped keys are rejected" {
    for ([_][]const u8{
        "{\"schema_version\":1,\"schema_version\":1}",
        "{\"\\u0073chema_version\":1,\"schema_version\":1}",
    }) |data| {
        var f = try Fixture.init();
        defer f.deinit();
        try f.pair(0, data);
        try f.expect("DuplicateField", &.{ paths[1], paths[6] });
    }
    var f = try Fixture.init();
    defer f.deinit();
    try f.write(paths[8], "{\"presets_sha256\":\"bad\",\"presets_sha256\":\"also bad\"}");
    try f.expect("DuplicateField", &.{ paths[8], paths[5] });
}

test "integer versions must match the expected schema" {
    const cases = [_]struct { project: []const u8, schema: []const u8, err: []const u8 }{
        .{ .project = "3", .schema = "3", .err = "SchemaVersionMismatch" },
        .{ .project = "true", .schema = "1", .err = "InvalidContractShape" },
        .{ .project = "1.0", .schema = "1", .err = "InvalidContractShape" },
    };
    for (cases) |case| {
        var f = try Fixture.init();
        defer f.deinit();
        const project = try std.fmt.allocPrint(a, "{{\"schema_version\":{s}}}", .{case.project});
        defer a.free(project);
        const schema = try std.fmt.allocPrint(a, "{{\"properties\":{{\"schema_version\":{{\"const\":{s}}}}}}}", .{case.schema});
        defer a.free(schema);
        try f.pair(0, project);
        try f.write(paths[6], schema);
        try f.expect(case.err, &.{});
    }
}

test "diagnostics never echo project contents" {
    var f = try Fixture.init();
    defer f.deinit();
    const secret = "do-not-echo-this-project-value";
    try f.pair(0, "{\"secret\":\"" ++ secret ++ "\"}");
    const r = try f.call(&.{ "--root", f.root_path }, f.unrelated);
    defer process.release(a, r);
    try std.testing.expectEqual(std.process.Child.Term{ .exited = 1 }, r.term);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "InvalidContractShape") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, paths[1]) != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, secret) == null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, secret) == null);
}

test "file size boundary accepts 4 MiB and rejects one extra byte" {
    var f = try Fixture.init();
    defer f.deinit();
    const original = try f.root.readFileAlloc(io, paths[1], a, .limited(4 * 1024 * 1024));
    defer a.free(original);
    const data = try a.alloc(u8, 4 * 1024 * 1024 + 1);
    defer a.free(data);
    @memset(data, ' ');
    @memcpy(data[0..original.len], original);
    try f.pair(0, data[0 .. data.len - 1]);
    try f.expect(null, &.{});
    try f.pair(0, data);
    try f.expect("FileTooLarge", &.{paths[0]});
}
