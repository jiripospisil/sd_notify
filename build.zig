const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "sd_notify",
        .root_source_file = b.path("src/sd_notify.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    b.installArtifact(lib);

    const examples = [_][]const u8{
        "basic",
        "fds",
    };
    for (examples) |example_name| {
        const file_path = b.fmt("examples/{s}.zig", .{example_name});

        const example = b.addExecutable(.{
            .name = b.fmt("examples-{s}", .{example_name}),
            .root_source_file = b.path(file_path),
            .target = target,
            .optimize = optimize,
        });
        example.root_module.addImport("sd_notify", &lib.root_module);

        b.installArtifact(example);
    }
}
