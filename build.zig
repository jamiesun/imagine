const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false;
    const svg_overlay = b.option(bool, "svg-overlay", "Enable SVG/PNG composition via resvg C API") orelse false;
    const resvg_include = b.option([]const u8, "resvg-include", "Directory containing resvg.h");
    const resvg_lib = b.option([]const u8, "resvg-lib", "Directory containing libresvg");
    // Extra system libraries to link alongside resvg. Rust staticlibs leave the
    // DWARF unwinder (_Unwind_*) to the final link, and Zig ships no libgcc_eh
    // for musl/mingw targets: pass e.g. -Dresvg-libs=gcc_eh with the toolchain's
    // libgcc_eh.a copied next to libresvg.a.
    const resvg_libs = b.option([]const u8, "resvg-libs", "Comma-separated extra libs to link with resvg (e.g. gcc_eh)");

    const exe = b.addExecutable(.{
        .name = "imagine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    const options = b.addOptions();
    options.addOption(bool, "svg_overlay_enabled", svg_overlay);
    exe.root_module.addOptions("build_options", options);

    exe.root_module.addIncludePath(b.path("src/c"));
    exe.root_module.addIncludePath(b.path("vendor/stb"));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/c/stb_shim.c") });
    exe.root_module.linkSystemLibrary("c", .{});

    if (svg_overlay) {
        exe.root_module.addIncludePath(b.path("vendor/resvg"));
        if (resvg_include) |p| {
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = p });
        } else {
            exe.root_module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        }
        if (resvg_lib) |p| {
            exe.root_module.addLibraryPath(.{ .cwd_relative = p });
            exe.root_module.addRPath(.{ .cwd_relative = p });
        } else {
            exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        }
        // Never let pkg-config inject a host-platform resvg: cross builds must
        // use exactly the library passed via -Dresvg-lib (pkg-config happily
        // returns a Mach-O/ELF library from another platform otherwise).
        // Force the static archive: resvg-capi also emits a shared library,
        // and zig prefers the dynamic one by default (which would leave the
        // released binary depending on libresvg.so/dylib/resvg.dll).
        exe.root_module.linkSystemLibrary("resvg", .{ .use_pkg_config = .no, .preferred_link_mode = .static });
        if (resvg_libs) |libs| {
            var it = std.mem.splitScalar(u8, libs, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len > 0) {
                    exe.root_module.linkSystemLibrary(trimmed, .{ .use_pkg_config = .no, .preferred_link_mode = .static });
                }
            }
        }
    }
    b.installArtifact(exe);

    // `zig build run -- <args>`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run imagine");
    run_step.dependOn(&run_cmd.step);

    // `zig build test`
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("build_options", options);
    unit_tests.root_module.addIncludePath(b.path("src/c"));
    unit_tests.root_module.addIncludePath(b.path("vendor/stb"));
    unit_tests.root_module.addCSourceFile(.{ .file = b.path("src/c/stb_shim.c") });
    unit_tests.root_module.linkSystemLibrary("c", .{});
    if (svg_overlay) {
        unit_tests.root_module.addIncludePath(b.path("vendor/resvg"));
        if (resvg_include) |p| {
            unit_tests.root_module.addSystemIncludePath(.{ .cwd_relative = p });
        } else {
            unit_tests.root_module.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
        }
        if (resvg_lib) |p| {
            unit_tests.root_module.addLibraryPath(.{ .cwd_relative = p });
            unit_tests.root_module.addRPath(.{ .cwd_relative = p });
        } else {
            unit_tests.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        }
        unit_tests.root_module.linkSystemLibrary("resvg", .{ .use_pkg_config = .no, .preferred_link_mode = .static });
        if (resvg_libs) |libs| {
            var it = std.mem.splitScalar(u8, libs, ',');
            while (it.next()) |name| {
                const trimmed = std.mem.trim(u8, name, " ");
                if (trimmed.len > 0) {
                    unit_tests.root_module.linkSystemLibrary(trimmed, .{ .use_pkg_config = .no, .preferred_link_mode = .static });
                }
            }
        }
    }
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
