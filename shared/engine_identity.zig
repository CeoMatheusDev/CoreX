//! Product identity compiled from the repository-root VERSION by shared/build.zig.
//! This is not the package SemVer, .proj schema, renderer contract, or ABI version.
const build_options = @import("build_options");
const product_version = @import("product_version.zig");

pub const version_string = build_options.engine_version;
pub const project_engine_version = build_options.project_engine_version;
pub const version = product_version.Version.parse(version_string) catch @compileError("build injected an invalid CoreX VERSION");
