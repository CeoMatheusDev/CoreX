//! Executable bootstrap slice: document/preset validation only.
//! Never reports runtime.ready, opens a fake viewport or simulates a fake core.
const std = @import("std");
const scope = @import("scope.zig");
const cli = @import("cli.zig");
const project = @import("project.zig");
const distribution = @import("distribution.zig");
const graphics_abi = @import("graphics_abi.zig");
const fingerprint = @import("fingerprint.zig");
const engine_identity = @import("engine_identity.zig");
const logging = @import("logging.zig");
const jsonl = @import("jsonl.zig");
const process = @import("platform_ext/process.zig");

pub const Exit = enum(u8) { success = 0, cli = 2, project = 3, unavailable = 4, child = 5, internal = 70, output = 74 };

/// A concrete execution backend supplied by the application entry point.
/// `shared` never links Core and never fabricates a runner: without one, an
/// execution request keeps reporting `application.core_unavailable` instead of
/// pretending that something ran.
pub const Runner = struct {
    context: ?*anyopaque = null,
    run: *const fn (?*anyopaque, RunRequest) anyerror!RunReport,
};

pub const RunRequest = struct {
    frames: u32,
};

pub const RunReport = struct {
    frames: u32,
    steps: u64,
    ticks: u64,
    input_ticks: u64,
    phase_remainder: u64,
};

/// Entry points share contracts, not process state. All owned buffers/documents
/// are destroyed before returning the exit code to main.
pub fn entry(init: std.process.Init, kind: cli.Kind) u8 {
    return entryWith(init, kind, null);
}

/// Same contract as `entry`, with an optional execution backend. The Editor and
/// the Runtime both call this; only the Runtime supplies a runner today.
pub fn entryWith(init: std.process.Init, kind: cli.Kind, runner: ?Runner) u8 {
    var logger = logging.Logger.init(init.io, kind);
    const code = collectArgs(init, kind, &logger, runner) catch |err| {
        if (err == error.LogSinkFailed) return @backingInt(Exit.output);
        logger.emit(.@"error", "application.internal_error", "Falha interna no bootstrap", .{ .code = @errorName(err) }) catch return @backingInt(Exit.output);
        return @backingInt(Exit.internal);
    };
    return @backingInt(code);
}

fn collectArgs(init: std.process.Init, kind: cli.Kind, logger: *logging.Logger, runner: ?Runner) !Exit {
    var iterator = try std.process.Args.iterateAllocator(init.minimal.args, init.gpa);
    defer iterator.deinit();
    _ = iterator.next();
    var arguments: [33][]const u8 = undefined;
    var count: usize = 0;
    while (iterator.next()) |arg| {
        if (count == arguments.len) {
            try logger.emit(.@"error", "cli.invalid", "Limite de argumentos excedido", .{ .code = "TooManyArguments" });
            return .cli;
        }
        arguments[count] = arg;
        count += 1;
    }
    return execute(init.gpa, init.io, kind, arguments[0..count], logger, runner);
}

fn execute(a: std.mem.Allocator, io: std.Io, kind: cli.Kind, arguments: []const []const u8, logger: *logging.Logger, runner: ?Runner) !Exit {
    const options = cli.parse(kind, arguments) catch |err| {
        try logger.emit(.@"error", "cli.invalid", "Argumentos invalidos; use --help", .{ .code = @errorName(err) });
        return .cli;
    };
    if (options.help) {
        try logger.emit(.info, "cli.help", "Bootstrap de validacao; execucao grafica/simulacao ainda indisponivel", .{
            .usage = if (kind == .editor) "CoreXEditor (--version | --project <file.proj> | <file.proj>) [--headless] [--validate-only] [--check-runtime <absolute-executable>]" else "CoreXRuntime (--version | --project <file.proj> [--headless] [--validate-only] | --project <file.proj> --headless --frames <1-1000000>)",
            .validation_scope = "document_and_presets",
            .core_linked = false,
        });
        return .success;
    }
    if (options.version) {
        try logger.emit(.info, "application.version", "Identidade de produto compilada no binario", .{
            .application = kind,
            .engine_version = engine_identity.version_string,
            .project_engine_version = engine_identity.project_engine_version,
            .distribution_manifest_format = @as(u32, 1),
            .core_abi_checked = false,
        });
        return .success;
    }
    try logger.emit(.info, "application.starting", "Inicializando validacao do projeto", .{ .headless = options.headless, .validate_only = options.validate_only, .core_linked = false });
    const path = std.Io.Dir.cwd().realPathFileAlloc(io, options.project.?, a) catch |err| {
        try logger.emit(.@"error", "project.read_failed", "Nao foi possivel resolver o arquivo de projeto", .{ .code = @errorName(err), .path = options.project.? });
        return .project;
    };
    defer a.free(path);
    if (!std.unicode.utf8ValidateSlice(path)) {
        try logger.emit(.@"error", "project.read_failed", "Caminho real do projeto nao pode ser representado em UTF-8", .{ .code = "UnsupportedProjectPathEncoding", .path = options.project.? });
        return .project;
    }
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1024 * 1024 + 1)) catch |err| {
        try logger.emit(.@"error", "project.read_failed", "Nao foi possivel ler o projeto dentro do limite", .{ .code = @errorName(err), .path = path });
        return .project;
    };
    defer a.free(bytes);
    var diagnostic: project.Diagnostic = .{};
    var document = project.parse(a, bytes, &diagnostic) catch |err| {
        try logger.emit(.@"error", "project.invalid", "Projeto invalido ou schema incompativel; schemas suportados: [1,2,3]", .{ .code = @errorName(err), .path = path, .pointer = diagnostic.pointer(), .supported_schema_versions = [_]u32{ 1, 2, 3 } });
        return .project;
    };
    defer document.deinit();
    try logger.emit(.info, "project.document_validated", "Documento validado; recursos da cena ainda nao foram carregados", .{ .path = path, .project_uuid = document.value.project.uuid, .schema_version = document.value.schema_version });
    const platform = scope.host() orelse {
        try logger.emit(.@"error", "application.platform_unsupported", "Produto suporta apenas Windows e Linux", .{ .code = "UnsupportedPlatform" });
        return .unavailable;
    };
    const decision = scope.decide(platform, document.value.engine.graphics_backend);
    try logger.emit(.info, "application.target_policy", "Elegibilidade nao comprova renderer ou capacidade GPU", .{
        .profile = scope.profile_id,
        .renderer_profile = document.value.renderer.profile,
        .host_platform = platform,
        .backend_requested = document.value.engine.graphics_backend,
        .decision = decision,
        .authoring_domains = [_]scope.AuthoringDomain{ .scene_3d, .ui_canvas },
        .scene_2d_supported = false,
        .gpu_created = false,
        .renderer_linked = false,
    });
    if (!options.validate_only and decision != .allowed) {
        try logger.emit(.@"error", "application.backend_unsupported", "Backend fora do perfil ou indisponivel neste SO; sem fallback", .{ .code = @tagName(decision), .backend_requested = document.value.engine.graphics_backend, .host_platform = platform });
        return .unavailable;
    }
    var bundle = distribution.load(a, io) catch |err| {
        const event = if (err == error.ManifestCorrupted) "distribution.manifest_corrupted" else "distribution.invalid";
        try logger.emit(.@"error", event, "Distribuicao ausente ou divergente; nao ha fallback de presets", .{ .code = @errorName(err) });
        return .unavailable;
    };
    defer bundle.deinit();
    const compatibility = distribution.classify(document.value.engine.version);
    if (compatibility == .incompatible) {
        try logger.emit(.@"error", "project.engine_incompatible", "A versao requerida nao esta na lista explicita de compatibilidade desta distribuicao", .{
            .required = document.value.engine.version,
            .packaged = bundle.manifest.value.engine_version,
            .project_engine_version = bundle.manifest.value.project_engine_version,
            .compatibility = compatibility,
            .core_abi_checked = false,
        });
        return .unavailable;
    }
    try logger.emit(.info, "project.engine_compatibility", "Compatibilidade de Engine aprovada pelo manifesto validado", .{
        .required = document.value.engine.version,
        .packaged = bundle.manifest.value.engine_version,
        .compatibility = compatibility,
        .core_abi_checked = false,
    });
    const params = bundle.table.value.resolve(document.value.renderer.graphics_preset, document.value.renderer.overrides) catch |err| {
        try logger.emit(.@"error", "presets.invalid_configuration", "Preset e overrides produzem configuracao invalida", .{ .code = @errorName(err) });
        return .project;
    };
    var dto = try graphics_abi.translate(params);
    if (graphics_abi.c.corex_graphics_validate_v1(&dto, @sizeOf(@TypeOf(dto))) != graphics_abi.c.COREX_GRAPHICS_OK) return error.GraphicsBoundaryMismatch;
    try logger.emit(.info, "graphics.config_resolved", "Parametros concretos resolvidos; nenhum device foi criado", .{
        .preset = document.value.renderer.graphics_preset,
        .renderer_profile_requested = document.value.renderer.profile,
        .backend_requested = document.value.engine.graphics_backend,
        .table_revision = bundle.manifest.value.table_revision,
        .table_sha256 = bundle.manifest.value.presets_sha256,
        .renderer_contract_version = bundle.manifest.value.renderer_contract_version,
        .headless = options.headless,
        .parameters = params,
        .overrides = document.value.renderer.overrides,
        .vsync = document.value.renderer.vsync,
        .initial_resolution = document.value.renderer.initial_resolution,
        .gpu_created = false,
        .capabilities_checked = false,
    });
    if (options.frames) |frames| {
        const execution = runner orelse {
            try logger.emit(.@"error", "application.core_unavailable", "Execucao headless solicitada sem executor ligado neste bootstrap", .{ .code = "CoreApplicationAdapterUnavailable", .headless = options.headless, .core_linked = false, .frames_requested = frames });
            return .unavailable;
        };
        // Execution here is deterministic and headless: no window, no GPU, no
        // scene and no presented frame. The counters come from the runner.
        try logger.emit(.info, "runtime.run_starting", "Execucao headless deterministica iniciada; sem janela, GPU, cena ou entrada real", .{
            .frames_requested = frames,
            .tick_hz = @as(u32, 60),
            .frame_ns = @as(u64, 16_666_667),
            .headless = true,
            .core_linked = true,
            .gpu_created = false,
            .window_created = false,
            .input_staged = false,
        });
        const report = execution.run(execution.context, .{ .frames = frames }) catch |err| {
            try logger.emit(.@"error", "runtime.run_failed", "Executor headless retornou erro; nenhum frame foi apresentado", .{ .code = @errorName(err), .core_linked = true, .gpu_created = false });
            return .internal;
        };
        try logger.emit(.info, "runtime.run_complete", "Execucao headless concluida; nenhum frame foi apresentado", .{
            .frames = report.frames,
            .steps = report.steps,
            .ticks = report.ticks,
            .input_ticks = report.input_ticks,
            .phase_remainder = report.phase_remainder,
            .presented_frames = @as(u32, 0),
            .play_started = false,
            .core_linked = true,
            .gpu_created = false,
            .window_created = false,
        });
        return .success;
    }
    if (!options.validate_only) {
        try logger.emit(.@"error", "application.core_unavailable", "Execucao grafica/simulacao nao implementada neste bootstrap; use --validate-only para verificar documentos", .{ .code = "CoreApplicationAdapterUnavailable", .headless = options.headless, .core_linked = false });
        return .unavailable;
    }
    const identity = try fingerprint.compute(document.value, params, bundle.manifest.value);
    try logger.emit(.info, if (kind == .runtime) "runtime.validation_complete" else "editor.validation_complete", "Validacao de documento e presets concluida", .{
        .scope = "document_and_presets",
        .fingerprint = &identity,
        .project_uuid = document.value.project.uuid,
        .core_linked = false,
        .core_abi_checked = false,
        .resources_loaded = false,
        .gpu_created = false,
    });
    if (options.check_runtime) |executable| {
        return checkRuntime(a, io, logger, executable, path, &identity);
    }
    return .success;
}

const ChildState = struct {
    frames: usize = 0,
    discarded: usize = 0,
    budget_reported: bool = false,
    sequences: std.AutoHashMapUnmanaged(u64, void) = .empty,
    expected_fingerprint: []const u8,
    matched: usize = 0,
    mismatch: bool = false,
    session: [128]u8 = undefined,
    session_len: usize = 0,
};
fn fieldString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const v = value.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn inspectFrame(a: std.mem.Allocator, logger: *logging.Logger, state: *ChildState, stream: []const u8, frame: jsonl.Frame, last_seq: *u64) !void {
    // Bound diagnostic amplification from thousands of empty/malformed lines.
    if (state.frames >= 4096) {
        state.discarded += 1;
        state.mismatch = true;
        if (!state.budget_reported) {
            state.budget_reported = true;
            try logger.emit(.warn, "runtime.output_invalid", "Limite de registros do filho excedido; restante descartado", .{ .code = "RecordBudgetExceeded", .limit = @as(u32, 4096) });
        }
        return;
    }
    state.frames += 1;
    switch (frame) {
        .oversized => |size| try logger.emit(.warn, "runtime.output_invalid", "Linha do filho excedeu o limite e foi descartada", .{ .stream = stream, .bytes = size, .code = "LineTooLong" }),
        .line => |line| {
            var parsed = jsonl.parse(a, line) catch |err| {
                if (err == error.OutOfMemory) return err;
                try logger.emit(.warn, "runtime.output_invalid", "Saida do filho nao segue o protocolo JSON lines", .{ .stream = stream, .code = @errorName(err), .raw_prefix = line[0..@min(line.len, 1024)], .bytes = line.len });
                return;
            };
            defer parsed.deinit();
            const record = parsed.value;
            const seq = try std.fmt.parseInt(u64, record.object.get("seq").?.number_string, 10);
            if (state.sequences.getOrPutAssumeCapacity(seq).found_existing) state.mismatch = true;
            if (seq <= last_seq.*) state.mismatch = true;
            last_seq.* = seq;
            const session = fieldString(record, "session_id").?;
            if (state.session_len == 0) {
                @memcpy(state.session[0..session.len], session);
                state.session_len = session.len;
            } else if (!std.mem.eql(u8, state.session[0..state.session_len], session)) state.mismatch = true;
            const event = fieldString(record, "event").?;
            if (std.mem.eql(u8, event, "runtime.validation_complete")) {
                const fields = record.object.get("fields").?;
                const identity = fieldString(fields, "fingerprint") orelse "";
                const completion_scope = fieldString(fields, "scope") orelse "";
                if (std.mem.eql(u8, fieldString(record, "source").?, "runtime") and std.mem.eql(u8, identity, state.expected_fingerprint) and std.mem.eql(u8, completion_scope, "document_and_presets")) state.matched += 1 else state.mismatch = true;
            }
            try logger.emit(.info, "runtime.output", "Registro do filho capturado (validacao, nao Play)", .{ .stream = stream, .record = record });
        },
    }
}

fn inspectStream(a: std.mem.Allocator, logger: *logging.Logger, state: *ChildState, stream: []const u8, bytes: []const u8) !void {
    var framer: jsonl.Framer = .{};
    var last_seq: u64 = 0;
    for (bytes) |byte| if (framer.push(byte)) |frame| try inspectFrame(a, logger, state, stream, frame, &last_seq);
    if (framer.finish()) |frame| try inspectFrame(a, logger, state, stream, frame, &last_seq);
}

fn checkRuntime(a: std.mem.Allocator, io: std.Io, logger: *logging.Logger, executable: []const u8, project_path: []const u8, identity: []const u8) !Exit {
    try logger.emit(.info, "runtime.check_starting", "Iniciando verificacao do Runtime em processo separado", .{ .executable = executable, .timeout_ms = @as(u32, 10000), .mode = "validate_only" });
    const child = process.runValidation(a, io, executable, project_path, 10000) catch |err| {
        try logger.emit(.@"error", "runtime.check_failed", "Falha ao supervisionar processo de validacao", .{ .code = @errorName(err) });
        return .child;
    };
    defer process.release(a, child);
    var state: ChildState = .{ .expected_fingerprint = identity };
    defer state.sequences.deinit(a);
    try state.sequences.ensureTotalCapacity(a, 4096);
    try inspectStream(a, logger, &state, "stdout", child.stdout);
    try inspectStream(a, logger, &state, "stderr", child.stderr);
    if (!child.term.success() or state.matched != 1 or state.mismatch) {
        try logger.emit(.@"error", "runtime.check_failed", "Filho falhou ou nao confirmou a mesma configuracao", .{
            .code = "ChildExitOrProtocolMismatch",
            .exit_code = if (child.term == .exited) @as(?u8, child.term.exited) else null,
            .matching_completions = state.matched,
            .discarded_frames = state.discarded,
            .protocol_mismatch = state.mismatch,
        });
        return .child;
    }
    try logger.emit(.info, "runtime.check_complete", "Editor e Runtime validaram a mesma configuracao em processos separados", .{ .fingerprint = identity, .mode = "validate_only", .play_started = false });
    return .success;
}
