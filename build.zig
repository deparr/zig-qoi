const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const exe = b.addExecutable(.{
        .name = "qoiconv",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    exe.addIncludePath(b.path("src/c"));
    exe.addCSourceFile(.{
        .file = b.path("src/c/stb.c"),
        .flags = &[_][]const u8{"-std=c99"},
    });
    exe.linkLibC();

    b.installArtifact(exe);
}
