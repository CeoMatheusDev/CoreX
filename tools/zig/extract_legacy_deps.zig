//! Extract only a pinned legacy release archive into a new private directory.
//! The SHA-256 is checked before decompression; this is not a general-purpose
//! extractor for arbitrary archives. Parents of the output must be trusted.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_archive = 16 * 1024 * 1024;
const max_uncompressed = 80 * 1024 * 1024;
const max_files_bytes = 64 * 1024 * 1024;
const max_entries = 100_000;

const Package = struct { name: []const u8, prefix: []const u8, sha256: []const u8 };
const packages = [_]Package{
    .{ .name = "zigway", .prefix = "Zigway-0.1.0-alpha.4", .sha256 = "07a4615916f50b14eac3241e763c499cf64c021f61a147dbd5ceb2ec02f723e0" },
    .{ .name = "zyntra_ui", .prefix = "ZyntraUI-1.44.1", .sha256 = "cd6a21c0821d8c1e3b525e15233fe41e9acc429c421122b19f2e160ebf714bee" },
};

fn unpackGzip(a: Allocator, bytes: []const u8, expected: []const u8, archive_limit: usize, unpacked_limit: usize) ![]u8 {
    if (bytes.len > archive_limit) return error.ArchiveTooLarge;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    const actual = std.fmt.bytesToHex(hash, .lower);
    if (!std.mem.eql(u8, &actual, expected)) return error.ArchiveHashMismatch;
    var source = Io.Reader.fixed(bytes);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decoder = std.compress.flate.Decompress.init(&source, .gzip, &window);
    const tar = decoder.reader.allocRemaining(a, .limited(unpacked_limit)) catch |err| {
        if (decoder.err) |detail| return detail;
        return err;
    };
    errdefer a.free(tar);
    const meta = decoder.container_metadata.gzip;
    if (meta.count != tar.len or meta.crc != std.hash.Crc32.hash(tar)) return error.GzipChecksumMismatch;
    if (source.seek != source.end) return error.TrailingGzipData;
    return tar;
}

fn relativeName(name: []const u8, prefix: []const u8, kind: std.tar.FileKind) ![]const u8 {
    if (std.mem.eql(u8, name, prefix)) {
        if (kind != .directory) return error.InvalidArchiveRoot;
        return "";
    }
    if (name.len <= prefix.len or !std.mem.startsWith(u8, name, prefix) or name[prefix.len] != '/')
        return error.UnsafeArchivePath;
    var rel = name[prefix.len + 1 ..];
    if (kind == .directory and rel.len > 0 and rel[rel.len - 1] == '/') rel = rel[0 .. rel.len - 1];
    if (rel.len == 0) {
        if (kind != .directory) return error.InvalidArchiveRoot;
        return rel;
    }
    if (std.mem.indexOfAny(u8, rel, "\\:") != null) return error.UnsafeArchivePath;
    var parts = std.mem.splitScalar(u8, rel, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, ".."))
            return error.UnsafeArchivePath;
    }
    return rel;
}

fn scanTar(tar: []const u8, prefix: []const u8, output: ?Io.Dir, io: Io, file_limit: u64, entry_limit: usize) !void {
    var reader = Io.Reader.fixed(tar);
    var names: [std.fs.max_path_bytes]u8 = undefined;
    var links: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(&reader, .{ .file_name_buffer = &names, .link_name_buffer = &links });
    var total: u64 = 0;
    var count: usize = 0;
    while (try iter.next()) |file| {
        count += 1;
        if (count > entry_limit) return error.TooManyArchiveEntries;
        if (file.kind == .sym_link) return error.UnsafeArchiveType;
        const rel = try relativeName(file.name, prefix, file.kind);
        if (file.size > file_limit - total) return error.ExtractedSizeLimit;
        total += file.size;
        if (file.kind == .directory and file.size != 0) return error.InvalidDirectorySize;
        if (output) |dir| {
            if (rel.len == 0) continue;
            if (file.kind == .directory) {
                try dir.createDirPath(io, rel);
            } else {
                if (std.fs.path.dirname(rel)) |parent| try dir.createDirPath(io, parent);
                const content = try reader.take(@intCast(file.size));
                iter.unread_file_bytes = 0;
                try dir.writeFile(io, .{ .sub_path = rel, .data = content, .flags = .{ .exclusive = true } });
            }
        }
    }
    if (count == 0) return error.EmptyArchive;
}

fn extract(a: Allocator, io: Io, bytes: []const u8, prefix: []const u8, digest: []const u8, output_path: []const u8) !void {
    const tar = try unpackGzip(a, bytes, digest, max_archive, max_uncompressed);
    defer a.free(tar);
    // Check every entry before creating output. The subsequent write pass uses
    // exclusive file creation in a fresh directory with no archive symlinks.
    try scanTar(tar, prefix, null, io, max_files_bytes, max_entries);
    const cwd = Io.Dir.cwd();
    try cwd.createDir(io, output_path, .default_dir);
    errdefer cwd.deleteTree(io, output_path) catch {};
    var out = try cwd.openDir(io, output_path, .{});
    defer out.close(io);
    try scanTar(tar, prefix, out, io, max_files_bytes, max_entries);
}

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Legacy archive extraction failed: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    var args = try std.process.Args.iterateAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const package_name = args.next() orelse return error.InvalidArguments;
    const archive_path = args.next() orelse return error.InvalidArguments;
    const output_path = args.next() orelse return error.InvalidArguments;
    if (args.next() != null or archive_path.len == 0 or output_path.len == 0) return error.InvalidArguments;
    var selected: ?Package = null;
    for (packages) |package| if (std.mem.eql(u8, package_name, package.name)) {
        selected = package;
        break;
    };
    const package = selected orelse return error.InvalidPackage;
    const data = try Io.Dir.cwd().readFileAlloc(init.io, archive_path, init.gpa, .limited(max_archive + 1));
    defer init.gpa.free(data);
    try extract(init.gpa, init.io, data, package.prefix, package.sha256, output_path);
    std.debug.print("{s}: verified archive and extracted safely\n", .{package.name});
}

fn tarSample(a: Allocator, path: []const u8, link: bool) ![]u8 {
    var bytes: Io.Writer.Allocating = .init(a);
    defer bytes.deinit();
    var writer: std.tar.Writer = .{ .underlying_writer = &bytes.writer };
    if (link) try writer.writeLink(path, "/tmp/escape", .{}) else try writer.writeFileBytes(path, "contents", .{});
    try bytes.writer.splatByteAll(0, 1024);
    return try a.dupe(u8, bytes.written());
}

test "tar paths and links are validated before extraction" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "pkg/../escape", "/pkg/file", "other/file", "pkg/./file", "pkg/a\\b", "pkg/C:escape" }) |path| {
        const tar = try tarSample(a, path, false);
        defer a.free(tar);
        try std.testing.expectError(error.UnsafeArchivePath, scanTar(tar, "pkg", null, io, max_files_bytes, max_entries));
    }
    const tar = try tarSample(a, "pkg/link", true);
    defer a.free(tar);
    try std.testing.expectError(error.UnsafeArchiveType, scanTar(tar, "pkg", null, io, max_files_bytes, max_entries));
}

test "extract valid archive contents with exclusive files" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const tar = try tarSample(a, "pkg/sub/file", false);
    defer a.free(tar);
    try scanTar(tar, "pkg", null, io, max_files_bytes, max_entries);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try scanTar(tar, "pkg", temp.dir, io, max_files_bytes, max_entries);
    const data = try temp.dir.readFileAlloc(io, "sub/file", a, .limited(100));
    defer a.free(data);
    try std.testing.expectEqualStrings("contents", data);
    try std.testing.expectError(error.PathAlreadyExists, scanTar(tar, "pkg", temp.dir, io, max_files_bytes, max_entries));
}

test "wrong hash is rejected before gzip decoding" {
    try std.testing.expectError(error.ArchiveHashMismatch, unpackGzip(std.testing.allocator, "invalid", "0000000000000000000000000000000000000000000000000000000000000000", max_archive, max_uncompressed));
}

fn gzipSample(a: Allocator, payload: []const u8) ![]u8 {
    var result: Io.Writer.Allocating = try .initCapacity(a, 1024);
    defer result.deinit();
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var writer = try std.compress.flate.Compress.init(&result.writer, &window, .gzip, .fastest);
    try writer.writer.writeAll(payload);
    try writer.finish();
    return a.dupe(u8, result.written());
}

fn testDigest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    return std.fmt.bytesToHex(hash, .lower);
}

test "gzip integrity, trailing bytes, and bounded input and output" {
    const a = std.testing.allocator;
    const compressed = try gzipSample(a, "hello world");
    defer a.free(compressed);
    const hash = testDigest(compressed);
    const decoded = try unpackGzip(a, compressed, &hash, compressed.len, 11);
    defer a.free(decoded);
    try std.testing.expectEqualStrings("hello world", decoded);
    try std.testing.expectError(error.ArchiveTooLarge, unpackGzip(a, compressed, &hash, compressed.len - 1, 11));
    try std.testing.expectError(error.StreamTooLong, unpackGzip(a, compressed, &hash, compressed.len, 10));
    const corrupt = try a.dupe(u8, compressed);
    defer a.free(corrupt);
    corrupt[corrupt.len - 8] ^= 1;
    const corrupt_hash = testDigest(corrupt);
    try std.testing.expectError(error.GzipChecksumMismatch, unpackGzip(a, corrupt, &corrupt_hash, max_archive, max_uncompressed));
    const trailing = try std.mem.concat(a, u8, &.{ compressed, "garbage" });
    defer a.free(trailing);
    const trailing_hash = testDigest(trailing);
    try std.testing.expectError(error.TrailingGzipData, unpackGzip(a, trailing, &trailing_hash, max_archive, max_uncompressed));
}

test "tar entry and content limits are enforced" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const tar = try tarSample(a, "pkg/file", false);
    defer a.free(tar);
    try scanTar(tar, "pkg", null, io, 8, 1);
    try std.testing.expectError(error.ExtractedSizeLimit, scanTar(tar, "pkg", null, io, 7, 1));
    try std.testing.expectError(error.TooManyArchiveEntries, scanTar(tar, "pkg", null, io, 8, 0));
}

test "authenticated extraction creates only a new destination" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{temp.sub_path});
    defer a.free(path);
    const tar = try tarSample(a, "pkg/sub/file", false);
    defer a.free(tar);
    const compressed = try gzipSample(a, tar);
    defer a.free(compressed);
    const hash = testDigest(compressed);
    try std.testing.expectError(error.ArchiveHashMismatch, extract(a, io, compressed, "pkg", "bad", path));
    try std.testing.expectError(error.FileNotFound, temp.dir.openDir(io, "out", .{}));
    try extract(a, io, compressed, "pkg", &hash, path);
    const data = try temp.dir.readFileAlloc(io, "out/sub/file", a, .limited(100));
    defer a.free(data);
    try std.testing.expectEqualStrings("contents", data);
    try std.testing.expectError(error.PathAlreadyExists, extract(a, io, compressed, "pkg", &hash, path));
    const still_there = try temp.dir.readFileAlloc(io, "out/sub/file", a, .limited(100));
    defer a.free(still_there);
    try std.testing.expectEqualStrings("contents", still_there);
}

test "unsafe entries never create an output directory" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{temp.sub_path});
    defer a.free(path);
    const cases = [_]struct { path: []const u8, link: bool, expected: anyerror }{
        .{ .path = "pkg/../escape", .link = false, .expected = error.UnsafeArchivePath },
        .{ .path = "/pkg/file", .link = false, .expected = error.UnsafeArchivePath },
        .{ .path = "other/file", .link = false, .expected = error.UnsafeArchivePath },
        .{ .path = "pkg/link", .link = true, .expected = error.UnsafeArchiveType },
    };
    for (cases) |case| {
        const tar = try tarSample(a, case.path, case.link);
        defer a.free(tar);
        const compressed = try gzipSample(a, tar);
        defer a.free(compressed);
        const hash = testDigest(compressed);
        try std.testing.expectError(case.expected, extract(a, io, compressed, "pkg", &hash, path));
        try std.testing.expectError(error.FileNotFound, temp.dir.openDir(io, "out", .{}));
    }
}

test "corrupt headers and truncated gzip are rejected" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const tar = try tarSample(a, "pkg/file", false);
    defer a.free(tar);
    tar[0] ^= 1;
    try std.testing.expectError(error.TarHeaderChksum, scanTar(tar, "pkg", null, io, max_files_bytes, max_entries));
    const compressed = try gzipSample(a, "hello");
    defer a.free(compressed);
    const truncated = compressed[0 .. compressed.len - 2];
    const hash = testDigest(truncated);
    if (unpackGzip(a, truncated, &hash, max_archive, max_uncompressed)) |bytes| {
        a.free(bytes);
        return error.TruncatedGzipAccepted;
    } else |_| {}
}

test "duplicate files fail without retaining partial output" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var buffer: Io.Writer.Allocating = .init(a);
    defer buffer.deinit();
    var writer: std.tar.Writer = .{ .underlying_writer = &buffer.writer };
    try writer.writeFileBytes("pkg/file", "first", .{});
    try writer.writeFileBytes("pkg/file", "second", .{});
    try buffer.writer.splatByteAll(0, 1024);
    const compressed = try gzipSample(a, buffer.written());
    defer a.free(compressed);
    const hash = testDigest(compressed);
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/out", .{temp.sub_path});
    defer a.free(path);
    try std.testing.expectError(error.PathAlreadyExists, extract(a, io, compressed, "pkg", &hash, path));
    try std.testing.expectError(error.FileNotFound, temp.dir.openDir(io, "out", .{}));
}

test "hard links and special files are unsupported" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_]u8{ '1', '3', '4', '6', '7' }) |kind| {
        const tar = try tarSample(a, "pkg/file", true);
        defer a.free(tar);
        tar[156] = kind;
        @memset(tar[148..156], ' ');
        var checksum: u64 = 0;
        for (tar[0..512]) |byte| checksum += byte;
        var octal: [6]u8 = undefined;
        _ = try std.fmt.bufPrint(&octal, "{o:0>6}", .{checksum});
        @memcpy(tar[148..154], &octal);
        tar[154] = 0;
        tar[155] = ' ';
        try std.testing.expectError(error.TarUnsupportedHeader, scanTar(tar, "pkg", null, io, max_files_bytes, max_entries));
    }
}
