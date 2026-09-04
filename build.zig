const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const h4 = b.addModule("h4", .{
        .root_source_file = b.path("common/h4.zig"),
        .target = target,
        .optimize = optimize,
    });

    const daemon = b.addExecutable(.{
        .name = "hcibridged",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "h4", .module = h4 }},
        }),
    });
    b.installArtifact(daemon);

    const sim = b.addExecutable(.{
        .name = "hcibridge-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/sim.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "h4", .module = h4 }},
        }),
    });
    b.installArtifact(sim);

    const test_step = b.step("test", "Run unit and integration tests");
    const test_roots = [_][]const u8{ "common/h4.zig", "host/main.zig", "host/sim.zig", "host/integration_test.zig" };
    for (test_roots) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "h4", .module = h4 }},
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // ESP32 object. Needs the Espressif Zig fork for the esp32 CPU model,
    // so it is opt-in and never touched by the host build.
    if (b.option(bool, "firmware", "Build the ESP32 Zig object (needs Espressif Zig)") orelse false) {
        const query = std.Target.Query.parse(.{
            .arch_os_abi = "xtensa-freestanding-none",
            .cpu_features = "esp32",
        }) catch @panic("esp32 cpu model missing, use the Espressif Zig build");
        const fw_target = b.resolveTargetQuery(query);
        const fw_h4 = b.createModule(.{
            .root_source_file = b.path("common/h4.zig"),
            .target = fw_target,
            .optimize = optimize,
        });
        const obj = b.addObject(.{
            .name = "bridge",
            .root_module = b.createModule(.{
                .root_source_file = b.path("firmware/main/bridge.zig"),
                .target = fw_target,
                .optimize = optimize,
                .imports = &.{.{ .name = "h4", .module = fw_h4 }},
            }),
        });
        obj.bundle_compiler_rt = true;
        obj.link_function_sections = true;
        obj.link_data_sections = true;
        const install_obj = b.addInstallArtifact(obj, .{
            .dest_dir = .{ .override = .{ .custom = "obj" } },
        });
        b.step("firmware", "Build the ESP32 Zig object").dependOn(&install_obj.step);
    }

    const run_daemon = b.addRunArtifact(daemon);
    if (b.args) |args| run_daemon.addArgs(args);
    b.step("run", "Run hcibridged").dependOn(&run_daemon.step);

    const run_sim = b.addRunArtifact(sim);
    if (b.args) |args| run_sim.addArgs(args);
    b.step("sim", "Run the fake controller").dependOn(&run_sim.step);
}
