const std = @import("std");
const clay = @import("zclay");
const tb = @import("termbox.zig");
const ui = @import("ui.zig");
const input = @import("input.zig");

var should_quit = false;

/// Handle Clay errors
fn handleClayErrors(error_data: clay.ErrorData) callconv(.c) void {
    std.debug.print("Clay Error: {s}\n", .{error_data.error_text.chars[0..@intCast(error_data.error_text.length)]});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure Clay memory
    const num_elements = 8192;
    clay.setMaxElementCount(num_elements);

    const min_memory_size = clay.minMemorySize();
    const memory = try allocator.alloc(u8, min_memory_size);
    defer allocator.free(memory);

    const arena = clay.createArenaWithCapacityAndMemory(memory);

    // Initialize Termbox2
    tb.initialize(
        tb.OUTPUT_256,
        .default,
        .default,
        .default,
        false,
    );

    defer tb.close();

    // Initialize Clay
    _ = clay.initialize(
        arena,
        .{ .w = tb.width(), .h = tb.height() },
        .{ .error_handler_function = handleClayErrors, .user_data = null },
    );

    // Set text measurement function
    tb.setMeasureText();

    // Initialize application state
    var state = try ui.AppState.init(allocator);
    defer state.deinit();

    // Initial render
    var render_commands = ui.createLayout(&state);
    tb.render(render_commands);
    _ = tb.present();

    // Main event loop
    while (!should_quit) {
        try input.handleEvents(&state, &should_quit);

        // Update audio engine (for timers, fades, etc.)
        try state.audio_engine.update();

        // Re-render
        render_commands = ui.createLayout(&state);
        _ = tb.clear();
        tb.render(render_commands);
        _ = tb.present();

        // Small sleep to reduce CPU usage
        std.Thread.sleep(16 * std.time.ns_per_ms); // ~60 FPS
    }
}
