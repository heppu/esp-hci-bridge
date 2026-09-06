const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const h4 = b.addModule("h4", .{
        .root_source_file = b.path("common/h4.zig"),
        .target = target,
        .optimize = optimize,
    });

    const discovery = b.addModule("discovery", .{
        .root_source_file = b.path("common/discovery.zig"),
        .target = target,
        .optimize = optimize,
    });

    const version = b.option([]const u8, "version", "version string baked into the binary") orelse "dev";
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const build_options = options.createModule();

    const daemon = b.addExecutable(.{
        .name = "hcibridge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "h4", .module = h4 }, .{ .name = "discovery", .module = discovery }, .{ .name = "build_options", .module = build_options } },
        }),
    });
    b.installArtifact(daemon);

    const sim = b.addExecutable(.{
        .name = "hcibridge-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("host/sim.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{ .{ .name = "h4", .module = h4 }, .{ .name = "discovery", .module = discovery } },
        }),
    });
    b.installArtifact(sim);

    const test_step = b.step("test", "Run unit and integration tests");
    const test_roots = [_][]const u8{ "common/h4.zig", "common/discovery.zig", "host/main.zig", "host/spec.zig", "host/config.zig", "host/sim.zig", "host/httpc.zig", "host/integration_test.zig" };
    for (test_roots) |root| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = target,
                .optimize = optimize,
                .imports = &.{ .{ .name = "h4", .module = h4 }, .{ .name = "discovery", .module = discovery }, .{ .name = "build_options", .module = build_options } },
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

    // `zig build gen` emits man page and completions from the binary (spec).
    const gen_step = b.step("gen", "Generate man page and shell completions");
    const GenSpec = struct { args: []const []const u8, out: []const u8 };
    const gens = [_]GenSpec{
        .{ .args = &.{"man"}, .out = "hcibridge.1" },
        .{ .args = &.{ "completions", "bash" }, .out = "hcibridge.bash" },
        .{ .args = &.{ "completions", "zsh" }, .out = "_hcibridge" },
        .{ .args = &.{ "completions", "fish" }, .out = "hcibridge.fish" },
    };
    for (gens) |g| {
        const r = b.addRunArtifact(daemon);
        r.addArgs(g.args);
        const captured = r.captureStdOut(.{});
        const inst = b.addInstallFileWithDir(captured, .{ .custom = "gen" }, g.out);
        gen_step.dependOn(&inst.step);
    }

    // release cross builds also baked with the same version option.
    const run_daemon = b.addRunArtifact(daemon);
    if (b.args) |args| run_daemon.addArgs(args);
    b.step("run", "Run hcibridged").dependOn(&run_daemon.step);

    const run_sim = b.addRunArtifact(sim);
    if (b.args) |args| run_sim.addArgs(args);
    b.step("sim", "Run the fake controller").dependOn(&run_sim.step);

    // `zig build release` cross-compiles static binaries for common targets.
    const release_step = b.step("release", "Build static hcibridge for release targets");
    const triples = [_][]const u8{
        "x86_64-linux-musl",
        "aarch64-linux-musl",
        "arm-linux-musleabihf",
    };
    for (triples) |triple| {
        const rt = b.resolveTargetQuery(std.Target.Query.parse(.{ .arch_os_abi = triple }) catch unreachable);
        const rmods = struct {
            fn mod(bb: *std.Build, path: []const u8, t: std.Build.ResolvedTarget) *std.Build.Module {
                return bb.createModule(.{ .root_source_file = bb.path(path), .target = t, .optimize = .ReleaseSafe });
            }
        };
        const rh4 = rmods.mod(b, "common/h4.zig", rt);
        const rdisc = rmods.mod(b, "common/discovery.zig", rt);
        const exe = b.addExecutable(.{
            .name = "hcibridge",
            .root_module = b.createModule(.{
                .root_source_file = b.path("host/main.zig"),
                .target = rt,
                .optimize = .ReleaseSafe,
                .imports = &.{ .{ .name = "h4", .module = rh4 }, .{ .name = "discovery", .module = rdisc }, .{ .name = "build_options", .module = build_options } },
            }),
        });
        const inst = b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = triple } } });
        release_step.dependOn(&inst.step);
    }
}
