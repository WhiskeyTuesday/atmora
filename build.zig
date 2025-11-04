const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add clay-zig-bindings dependency
    const zclay_dep = b.dependency("zclay", .{
        .target = target,
        .optimize = optimize,
    });

    // Add zaudio (miniaudio wrapper) dependency
    const zaudio_dep = b.dependency("zaudio", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the root module
    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zclay", zclay_dep.module("zclay"));
    root_module.addImport("zaudio", zaudio_dep.module("root"));

    // Create the executable
    const exe = b.addExecutable(.{
        .name = "atmora",
        .root_module = root_module,
    });

    // Link zaudio's miniaudio library
    exe.linkLibrary(zaudio_dep.artifact("miniaudio"));

    // Add C source files for termbox2 renderer
    // On macOS, we need _DARWIN_C_SOURCE to get cfmakeraw and SIGWINCH
    const c_flags_macos = [_][]const u8{
        "-std=c11",
        "-DTB_OPT_ATTR_W=32",
        "-D_DARWIN_C_SOURCE",
    };
    const c_flags_linux = [_][]const u8{
        "-std=c11",
        "-DTB_OPT_ATTR_W=32",
        "-D_POSIX_C_SOURCE=200809L",
        "-D_DEFAULT_SOURCE",
    };
    const c_flags = if (target.result.os.tag == .macos)
        &c_flags_macos
    else
        &c_flags_linux;

    exe.addCSourceFile(.{
        .file = b.path("vendor/clay-renderer/clay_termbox_impl.c"),
        .flags = c_flags,
    });

    // Get clay.h from zclay's clay dependency
    const clay_dep = zclay_dep.builder.dependency("clay", .{});

    // Add include paths
    exe.addIncludePath(clay_dep.path(""));  // clay.h
    exe.addIncludePath(b.path("vendor/termbox2"));
    exe.addIncludePath(b.path("vendor/stb"));
    exe.addIncludePath(b.path("vendor/clay-renderer"));

    // Link libc and math library (required by stb_image)
    exe.linkLibC();
    exe.linkSystemLibrary("m");

    // Install the executable
    b.installArtifact(exe);

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run atmora");
    run_step.dependOn(&run_cmd.step);

    // Add test step
    const test_step = b.step("test", "Run unit tests");

    // Test audio module
    const audio_test_module = b.createModule(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_test_module.addImport("zaudio", zaudio_dep.module("root"));

    const audio_unit_tests = b.addTest(.{
        .root_module = audio_test_module,
    });
    audio_unit_tests.linkLibrary(zaudio_dep.artifact("miniaudio"));

    const run_audio_tests = b.addRunArtifact(audio_unit_tests);
    test_step.dependOn(&run_audio_tests.step);

    // Test presets module
    const presets_test_module = b.createModule(.{
        .root_source_file = b.path("src/presets.zig"),
        .target = target,
        .optimize = optimize,
    });

    const presets_unit_tests = b.addTest(.{
        .root_module = presets_test_module,
    });

    const run_presets_tests = b.addRunArtifact(presets_unit_tests);
    test_step.dependOn(&run_presets_tests.step);

    // Test modal module
    const modal_test_module = b.createModule(.{
        .root_source_file = b.path("src/modal.zig"),
        .target = target,
        .optimize = optimize,
    });

    const modal_unit_tests = b.addTest(.{
        .root_module = modal_test_module,
    });

    const run_modal_tests = b.addRunArtifact(modal_unit_tests);
    test_step.dependOn(&run_modal_tests.step);

    // Test UI module (includes dirty state tracking tests)
    const ui_test_module = b.createModule(.{
        .root_source_file = b.path("src/ui.zig"),
        .target = target,
        .optimize = optimize,
    });
    ui_test_module.addImport("zclay", zclay_dep.module("zclay"));
    ui_test_module.addImport("zaudio", zaudio_dep.module("root"));

    const ui_unit_tests = b.addTest(.{
        .root_module = ui_test_module,
    });
    ui_unit_tests.linkLibrary(zaudio_dep.artifact("miniaudio"));

    const run_ui_tests = b.addRunArtifact(ui_unit_tests);
    test_step.dependOn(&run_ui_tests.step);
}
