// SPDX-License-Identifier: CC0-1.0

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("fluxion_json", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "fluxion-json-tests",
        .root_module = mod,
    })).step);
    test_step.dependOn(&wasmCheck(b).step);

    const docs_lib = b.addLibrary(.{ .name = "fluxion-json", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_lib.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    b.step("docs", "Generate API documentation into zig-out/docs").dependOn(&install_docs.step);

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("examples/demo.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "fluxion_json", .module = mod }},
    });
    const demo = b.addExecutable(.{ .name = "fluxion-json-demo", .root_module = demo_mod });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_demo.addArgs(args);
    b.step("example", "A tour: read, change, write, load and save").dependOn(&run_demo.step);

    test_step.dependOn(&b.addRunArtifact(b.addTest(.{
        .name = "fluxion-json-demo-tests",
        .root_module = demo_mod,
    })).step);

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("examples/bench.zig"),
        .target = target,
        .optimize = if (optimize == .Debug) .ReleaseFast else optimize,
        .imports = &.{.{ .name = "fluxion_json", .module = mod }},
    });
    const bench = b.addExecutable(.{ .name = "fluxion-json-bench", .root_module = bench_mod });
    const run_bench = b.addRunArtifact(bench);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Time reading and writing against std.json").dependOn(&run_bench.step);
}

/// The library built for a browser, so a change that would not compile for
/// `wasm32-freestanding` fails the suite rather than a page. See
/// `src/wasm_check.zig`.
fn wasmCheck(b: *std.Build) *std.Build.Step.Compile {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const json = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
    });
    const check = b.addExecutable(.{
        .name = "fluxion-json-wasm-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/wasm_check.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "fluxion_json", .module = json }},
        }),
    });
    check.entry = .disabled;
    check.rdynamic = true;
    return check;
}
