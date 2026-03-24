const std = @import("std");

pub fn build(b: *std.Build) void {
    const options = b.addOptions();
    options.addOption(bool, "trace", b.option(bool, "trace", "show debug trace output") orelse false);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zroaring", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build-options", .module = options.createModule() }},
    });

    const tests = b.addTest(.{
        .root_module = mod,
        .filters = if (b.option([]const []const u8, "test-filter", "filter tests")) |o| o else &.{},
    });
    const avx512 = b.option(bool, "avx512", "enable croaring avx512.  default false.") orelse false;
    tests.root_module.addIncludePath(b.path("src"));
    tests.root_module.addCSourceFile(.{ .file = b.path("src/c/roaring.c") });
    tests.root_module.addCMacro(if (avx512) "" else "CROARING_COMPILER_SUPPORTS_AVX512", "0");
    tests.root_module.link_libc = true;
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    b.installArtifact(tests);

    const lib = b.addLibrary(.{ .root_module = mod, .name = "zroaring" });
    const docs = b.addInstallDirectory(.{
        .source_dir = lib.getEmittedDocs(),
        .install_dir = .{ .prefix = {} },
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate documentation to zig-out/docs.");
    docs_step.dependOn(&docs.step);

    const exe_check = b.addExecutable(.{ .name = "check", .root_module = mod });
    const check = b.step("check", "Check if everything compiles");
    check.dependOn(&exe_check.step);
    check.dependOn(&tests.step);
}
