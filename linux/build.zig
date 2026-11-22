//! Iris for Linux: Zig, GTK 4 and libadwaita for the window, WPE WebKit
//! (its WPEPlatform API) for the pages.
//!
//!   zig build              the program, zig-out/bin/iris
//!   zig build test         the tests (no display needed)
//!   zig build -Doptimize=ReleaseFast
//!
//! Needs Zig 0.15.2 and the development files of libadwaita-1, gtk4 (4.14+),
//! wpe-webkit-2.0 and wpe-platform-2.0 (WPE WebKit 2.54+, built with
//! ENABLE_WPE_PLATFORM), libsoup-3.0 and wayland-client.
const std = @import("std");

/// pkg-config modules for the C headers and the linker
const libs = [_][]const u8{ "libadwaita-1", "gtk4", "gtk4-wayland", "wpe-webkit-2.0", "wpe-platform-2.0", "wpe-platform-headless-2.0", "libsoup-3.0", "wayland-client", "libdrm" };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // the C headers, translated once into the module `c` (the build
    // system's TranslateC: @cImport is deprecated in Zig)
    const tc = b.addTranslateC(.{ .root_source_file = b.path("src/c.h"), .target = target, .optimize = optimize, .link_libc = true });
    tc.addIncludePath(b.path("c"));
    for (includeDirs(b)) |dir| tc.addSystemIncludePath(.{ .cwd_relative = dir });
    const cmod = tc.createModule();

    // Iris's ~100,000 ad and tracker domains as native Zig arrays, sorted,
    // made at build time from the gzipped list (gzip, then tools/domains.zig)
    const rules = b.createModule(.{ .root_source_file = b.path("src/rules.zig"), .target = b.graph.host, .optimize = .ReleaseSafe });
    const gen = b.addExecutable(.{ .name = "domains", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/domains.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "rules", .module = rules }},
    }) });
    const gunzip = b.addSystemCommand(&.{ "gzip", "-dc" });
    gunzip.addFileArg(b.path("src/shield-domains.json.gz"));
    const listJSON = gunzip.captureStdOut();
    const genRun = b.addRunArtifact(gen);
    genRun.addFileArg(listJSON);
    const domainsZig = genRun.addOutputFileArg("domains.zig");
    const domains = b.createModule(.{ .root_source_file = domainsZig });

    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "c", .module = cmod }, .{ .name = "domains", .module = domains } },
    });
    // the compositor's background blur: Iris's own C, and the protocol code
    // wayland-scanner made
    mod.addIncludePath(b.path("c"));
    mod.addCSourceFiles(.{ .files = &.{ "c/blur.c", "c/ext-background-effect-v1-protocol.c" }, .flags = &.{"-std=c11"} });
    for (libs) |l| mod.linkSystemLibrary(l, .{});
    mod.linkSystemLibrary("m", .{});

    const exe = b.addExecutable(.{ .name = "iris", .root_module = mod });
    b.installArtifact(exe);
    // icons for the menus and containers
    b.installDirectory(.{ .source_dir = b.path("resources/icons"), .install_dir = .prefix, .install_subdir = "share/iris/icons" });

    const run = b.addRunArtifact(exe);
    if (b.args) |a| run.addArgs(a);
    b.step("run", "Run Iris").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "c", .module = cmod }, .{ .name = "domains", .module = domains } },
    }) });
    tests.root_module.addIncludePath(b.path("c"));
    tests.root_module.addCSourceFiles(.{ .files = &.{ "c/blur.c", "c/ext-background-effect-v1-protocol.c" }, .flags = &.{"-std=c11"} });
    for (libs) |l| tests.root_module.linkSystemLibrary(l, .{});
    tests.root_module.linkSystemLibrary("m", .{});
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}

/// the header folders pkg-config gives for every library
fn includeDirs(b: *std.Build) []const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    args.appendSlice(b.allocator, &.{ "pkg-config", "--cflags-only-I" }) catch @panic("out of memory");
    args.appendSlice(b.allocator, &libs) catch @panic("out of memory");
    const out = b.run(args.items);
    var dirs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, out, " \n");
    while (it.next()) |f| if (std.mem.startsWith(u8, f, "-I")) dirs.append(b.allocator, f[2..]) catch {};
    return dirs.items;
}
