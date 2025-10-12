const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_tool = b.option(bool, "tool", "Build qoi cli tool") orelse true;

    const qoi_mod = b.addModule("qoi", .{
        .root_source_file = b.path("src/qoi.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (build_tool) {
        const exe = b.addExecutable(.{
            .name = "qoi",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const zigimg_dep = b.dependency("zigimg", .{
            .target = target,
            .optimize = optimize,
        });

        exe.root_module.addImport("zigimg", zigimg_dep.module("zigimg"));
        exe.root_module.addImport("qoi", qoi_mod);

        b.installArtifact(exe);
    }

}
