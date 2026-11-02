//! Independent fixture consistency checker. No dependency on application parser.
//! Files are read at runtime; running from the repository root is the default.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const max_file_bytes = 4 * 1024 * 1024;

const Inputs = struct {
    v1_example: []const u8,
    v1_fixture: []const u8,
    v2_example: []const u8,
    v2_fixture: []const u8,
    presets_example: []const u8,
    presets_fixture: []const u8,
    v1_schema: []const u8,
    v2_schema: []const u8,
    manifest: []const u8,
};

fn field(value: std.json.Value, name: []const u8) !std.json.Value {
    if (value != .object) return error.InvalidContractShape;
    return value.object.get(name) orelse error.InvalidContractShape;
}

fn schemaVersion(value: std.json.Value) !i64 {
    const properties = try field(value, "properties");
    const version = try field(try field(properties, "schema_version"), "const");
    if (version != .integer) return error.InvalidContractShape;
    return version.integer;
}

fn projectVersion(value: std.json.Value) !i64 {
    const version = try field(value, "schema_version");
    if (version != .integer) return error.InvalidContractShape;
    return version.integer;
}

fn checkVersions(a: Allocator, schema: []const u8, project: []const u8, expected: i64) !void {
    var schema_json = try std.json.parseFromSlice(std.json.Value, a, schema, .{});
    defer schema_json.deinit();
    var project_json = try std.json.parseFromSlice(std.json.Value, a, project, .{});
    defer project_json.deinit();
    if (try schemaVersion(schema_json.value) != expected or try projectVersion(project_json.value) != expected)
        return error.SchemaVersionMismatch;
}

fn checkBackends(a: Allocator, schema: []const u8) !void {
    var doc = try std.json.parseFromSlice(std.json.Value, a, schema, .{});
    defer doc.deinit();
    const root_properties = try field(doc.value, "properties");
    const engine_properties = try field(try field(root_properties, "engine"), "properties");
    const backend = try field(engine_properties, "graphics_backend");
    const values = try field(backend, "enum");
    if (values != .array) return error.InvalidContractShape;
    const expected = [_][]const u8{ "vulkan", "opengl", "d3d11", "d3d12" };
    if (values.array.items.len != expected.len) return error.BackendMismatch;
    for (values.array.items, expected) |value, name| {
        if (value != .string or !std.mem.eql(u8, value.string, name)) return error.BackendMismatch;
    }
}

fn checkHash(a: Allocator, manifest: []const u8, presets: []const u8) !void {
    var doc = try std.json.parseFromSlice(std.json.Value, a, manifest, .{});
    defer doc.deinit();
    const expected = try field(doc.value, "presets_sha256");
    if (expected != .string) return error.InvalidContractShape;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(presets, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, expected.string, &actual)) return error.PresetsHashMismatch;
}

fn contextualError(err: anyerror, context: []const u8) anyerror {
    // Unit tests assert the errors directly; the standalone CLI reports the
    // relevant files and stage without printing potentially sensitive input.
    if (!@import("builtin").is_test) std.debug.print("Fixture check ({s}): {s}\n", .{ context, @errorName(err) });
    return err;
}

fn verify(a: Allocator, input: Inputs) !void {
    if (!std.mem.eql(u8, input.v1_example, input.v1_fixture))
        return contextualError(error.V1FixtureMismatch, "docs/examples/EmptyGame.proj vs shared/fixtures/EmptyGame.proj");
    if (!std.mem.eql(u8, input.v2_example, input.v2_fixture))
        return contextualError(error.V2FixtureMismatch, "docs/examples/EmptyGameV2.proj vs shared/fixtures/EmptyGameV2.proj");
    if (!std.mem.eql(u8, input.presets_example, input.presets_fixture))
        return contextualError(error.PresetsFixtureMismatch, "docs/examples/presets.zon vs shared/fixtures/presets.zon");
    checkVersions(a, input.v1_schema, input.v1_fixture, 1) catch |err|
        return contextualError(err, "v1 version: docs/schemas/project-v1.schema.json and shared/fixtures/EmptyGame.proj");
    checkVersions(a, input.v2_schema, input.v2_fixture, 2) catch |err|
        return contextualError(err, "v2 version: docs/schemas/project-v2.schema.json and shared/fixtures/EmptyGameV2.proj");
    checkBackends(a, input.v2_schema) catch |err|
        return contextualError(err, "v2 backends: docs/schemas/project-v2.schema.json");
    checkHash(a, input.manifest, input.presets_fixture) catch |err|
        return contextualError(err, "presets hash: shared/fixtures/distribution.template.json and shared/fixtures/presets.zon");
}

fn readFile(a: Allocator, io: Io, root: Io.Dir, path: []const u8) ![]u8 {
    const bytes = root.readFileAlloc(io, path, a, .limited(max_file_bytes + 1)) catch |err| {
        if (err == error.StreamTooLong) {
            if (!@import("builtin").is_test) std.debug.print("File exceeds limit: {s}\n", .{path});
            return error.FileTooLarge;
        }
        if (!@import("builtin").is_test) std.debug.print("Cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    if (bytes.len > max_file_bytes) {
        a.free(bytes);
        if (!@import("builtin").is_test) std.debug.print("File exceeds limit: {s}\n", .{path});
        return error.FileTooLarge;
    }
    return bytes;
}

fn checkRoot(a: Allocator, io: Io, root: Io.Dir) !void {
    // An arena gives one cleanup path even if any read or validation fails.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem = arena.allocator();
    const input: Inputs = .{
        .v1_example = try readFile(mem, io, root, "docs/examples/EmptyGame.proj"),
        .v1_fixture = try readFile(mem, io, root, "shared/fixtures/EmptyGame.proj"),
        .v2_example = try readFile(mem, io, root, "docs/examples/EmptyGameV2.proj"),
        .v2_fixture = try readFile(mem, io, root, "shared/fixtures/EmptyGameV2.proj"),
        .presets_example = try readFile(mem, io, root, "docs/examples/presets.zon"),
        .presets_fixture = try readFile(mem, io, root, "shared/fixtures/presets.zon"),
        .v1_schema = try readFile(mem, io, root, "docs/schemas/project-v1.schema.json"),
        .v2_schema = try readFile(mem, io, root, "docs/schemas/project-v2.schema.json"),
        .manifest = try readFile(mem, io, root, "shared/fixtures/distribution.template.json"),
    };
    try verify(mem, input);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Fixture check failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var args = try std.process.Args.iterateAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    var root_path: []const u8 = ".";
    if (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            if (args.next() != null) return error.InvalidArguments;
            try Io.File.stdout().writeStreamingAll(init.io, "Usage: corex-check-fixtures [--root REPOSITORY_ROOT]\nDefault: current working directory.\n");
            return;
        }
        if (!std.mem.eql(u8, arg, "--root")) return error.InvalidArguments;
        root_path = args.next() orelse return error.InvalidArguments;
        if (root_path.len == 0 or args.next() != null) return error.InvalidArguments;
    }
    var root = Io.Dir.cwd().openDir(init.io, root_path, .{}) catch |err| {
        std.debug.print("Cannot open repository root {s}: {s}\n", .{ root_path, @errorName(err) });
        return err;
    };
    defer root.close(init.io);
    try checkRoot(init.gpa, init.io, root);
    try Io.File.stdout().writeStreamingAll(init.io, "OK: fixtures, versions, backend list and presets SHA-256 match.\n");
}

const sample_v1 = "{\"schema_version\":1}";
const sample_v2 = "{\"schema_version\":2}";
const schema_v1 = "{\"properties\":{\"schema_version\":{\"const\":1}}}";
const schema_v2 = "{\"properties\":{\"schema_version\":{\"const\":2},\"engine\":{\"properties\":{\"graphics_backend\":{\"enum\":[\"vulkan\",\"opengl\",\"d3d11\",\"d3d12\"]}}}}}";
const sample_presets = "abc";
const sample_manifest = "{\"presets_sha256\":\"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad\"}";
const valid: Inputs = .{
    .v1_example = sample_v1,
    .v1_fixture = sample_v1,
    .v2_example = sample_v2,
    .v2_fixture = sample_v2,
    .presets_example = sample_presets,
    .presets_fixture = sample_presets,
    .v1_schema = schema_v1,
    .v2_schema = schema_v2,
    .manifest = sample_manifest,
};

test "valid fixtures and all pair mismatches" {
    const a = std.testing.allocator;
    try verify(a, valid);
    var input = valid;
    input.v1_example = "bad";
    try std.testing.expectError(error.V1FixtureMismatch, verify(a, input));
    input = valid;
    input.v2_fixture = "bad";
    try std.testing.expectError(error.V2FixtureMismatch, verify(a, input));
    input = valid;
    input.presets_example = "bad";
    try std.testing.expectError(error.PresetsFixtureMismatch, verify(a, input));
}

test "schema and example versions are checked independently" {
    var input = valid;
    input.v1_schema = "{\"properties\":{\"schema_version\":{\"const\":2}}}";
    try std.testing.expectError(error.SchemaVersionMismatch, verify(std.testing.allocator, input));
    input = valid;
    input.v2_example = "{\"schema_version\":3}";
    input.v2_fixture = input.v2_example;
    try std.testing.expectError(error.SchemaVersionMismatch, verify(std.testing.allocator, input));
    input = valid;
    input.v1_schema = "{}";
    try std.testing.expectError(error.InvalidContractShape, verify(std.testing.allocator, input));
}

test "v2 backend order and manifest hash are checked" {
    var input = valid;
    input.v2_schema = "{\"properties\":{\"schema_version\":{\"const\":2},\"engine\":{\"properties\":{\"graphics_backend\":{\"enum\":[\"opengl\",\"vulkan\",\"d3d11\",\"d3d12\"]}}}}}";
    try std.testing.expectError(error.BackendMismatch, verify(std.testing.allocator, input));
    input = valid;
    input.presets_example = "modified";
    input.presets_fixture = input.presets_example;
    try std.testing.expectError(error.PresetsHashMismatch, verify(std.testing.allocator, input));
    input = valid;
    input.manifest = "{}";
    try std.testing.expectError(error.InvalidContractShape, verify(std.testing.allocator, input));
}

test "malformed JSON and duplicate keys are rejected" {
    var input = valid;
    input.manifest = "{";
    try std.testing.expectError(error.UnexpectedEndOfInput, verify(std.testing.allocator, input));
    input = valid;
    input.v1_schema = "{\"properties\":{},\"properties\":{}}";
    try std.testing.expectError(error.DuplicateField, verify(std.testing.allocator, input));
}

fn writeTestFiles(dir: Io.Dir) !void {
    const io = std.testing.io;
    try dir.createDirPath(io, "docs/examples");
    try dir.createDirPath(io, "docs/schemas");
    try dir.createDirPath(io, "shared/fixtures");
    const files = [_]struct { path: []const u8, content: []const u8 }{
        .{ .path = "docs/examples/EmptyGame.proj", .content = sample_v1 },
        .{ .path = "shared/fixtures/EmptyGame.proj", .content = sample_v1 },
        .{ .path = "docs/examples/EmptyGameV2.proj", .content = sample_v2 },
        .{ .path = "shared/fixtures/EmptyGameV2.proj", .content = sample_v2 },
        .{ .path = "docs/examples/presets.zon", .content = sample_presets },
        .{ .path = "shared/fixtures/presets.zon", .content = sample_presets },
        .{ .path = "docs/schemas/project-v1.schema.json", .content = schema_v1 },
        .{ .path = "docs/schemas/project-v2.schema.json", .content = schema_v2 },
        .{ .path = "shared/fixtures/distribution.template.json", .content = sample_manifest },
    };
    for (files) |file| try dir.writeFile(io, .{ .sub_path = file.path, .data = file.content });
}

test "filesystem reads runtime data and catches changes and missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir = try tmp.dir.createDirPathOpen(std.testing.io, "Jogo ação", .{});
    defer dir.close(std.testing.io);
    try writeTestFiles(dir);
    try checkRoot(std.testing.allocator, std.testing.io, dir);
    try dir.writeFile(std.testing.io, .{ .sub_path = "shared/fixtures/EmptyGame.proj", .data = "changed" });
    try std.testing.expectError(error.V1FixtureMismatch, checkRoot(std.testing.allocator, std.testing.io, dir));
    try dir.writeFile(std.testing.io, .{ .sub_path = "shared/fixtures/EmptyGame.proj", .data = sample_v1 });
    try dir.deleteFile(std.testing.io, "docs/examples/presets.zon");
    try std.testing.expectError(error.FileNotFound, checkRoot(std.testing.allocator, std.testing.io, dir));
}

test "filesystem rejects oversized input without modifying it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFiles(tmp.dir);
    const large = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "docs/examples/EmptyGame.proj", .data = large });
    try std.testing.expectError(error.FileTooLarge, checkRoot(std.testing.allocator, std.testing.io, tmp.dir));
    const file = try tmp.dir.openFile(std.testing.io, "docs/examples/EmptyGame.proj", .{});
    defer file.close(std.testing.io);
    try std.testing.expectEqual(@as(u64, max_file_bytes + 1), (try file.stat(std.testing.io)).size);
}

fn allocationProbe(a: Allocator) !void {
    try verify(a, valid);
}

test "validation releases allocations on injected failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationProbe, .{});
}
