const std = @import("std");
const clay = @import("zclay");
const audio = @import("audio.zig");
const FileBrowser = @import("filebrowser.zig").FileBrowser;
const presets = @import("presets.zig");
const modal = @import("modal.zig");

// Color definitions
pub const color_bg: clay.Color = .{ 224, 215, 210, 255 };
pub const color_container: clay.Color = .{ 36, 36, 36, 255 };

// visible over both bg and container colors
pub const color_text: clay.Color = .{ 65, 65, 65, 255 };
pub const color_accent1: clay.Color = .{ 125, 138, 50, 255 };
pub const color_accent2: clay.Color = .{ 100, 180, 255, 255 };

pub const color_error: clay.Color = .{ 220, 50, 50, 255 };
pub const color_warn: clay.Color = .{ 255, 165, 0, 255 };
pub const color_success: clay.Color = .{ 50, 200, 100, 255 };

pub const debug_color_hot_pink: clay.Color = .{ 255, 105, 180, 255 };

// Pending toast for queue
const PendingToast = struct {
    message: []const u8, // Static string, no allocation needed
    level: modal.ToastLevel,
    duration_ms: i64,
};

// Application state (shared with main)
/// Snapshot of preset state for dirty tracking
const PresetSnapshot = struct {
    channels: []ChannelSnapshot,
    allocator: std.mem.Allocator,

    const ChannelSnapshot = struct {
        path: []const u8,
        volume: u8,
        loop: bool,
    };

    pub fn deinit(self: *PresetSnapshot) void {
        for (self.channels) |ch| {
            self.allocator.free(ch.path);
        }
        self.allocator.free(self.channels);
    }
};

pub const AppState = struct {
    audio_engine: audio.AudioEngine,
    file_browser: FileBrowser,
    preset_manager: presets.PresetManager,
    selected_channel: ?usize,
    last_error: ?[]const u8,
    current_preset_name: ?[]const u8,
    preset_snapshot: ?PresetSnapshot, // State when preset was loaded/saved
    pending_preset_name: ?[]const u8, // Preset name waiting to be loaded after confirmation
    active_modal: modal.Modal,
    toast_queue: std.ArrayList(PendingToast),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !AppState {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.fs.cwd().realpath(".", &buf);

        return AppState{
            .audio_engine = try audio.AudioEngine.init(allocator),
            .file_browser = try FileBrowser.init(allocator, cwd),
            .preset_manager = try presets.PresetManager.init(allocator),
            .selected_channel = null,
            .last_error = null,
            .current_preset_name = null,
            .preset_snapshot = null,
            .pending_preset_name = null,
            .active_modal = modal.Modal.none(),
            .toast_queue = std.ArrayList(PendingToast){ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *AppState) void {
        self.audio_engine.deinit();
        self.file_browser.deinit();
        self.preset_manager.deinit();
        self.toast_queue.deinit(self.allocator);
        if (self.current_preset_name) |name| {
            self.allocator.free(name);
        }
        if (self.pending_preset_name) |name| {
            self.allocator.free(name);
        }
        if (self.preset_snapshot) |*snapshot| {
            var mut_snapshot = snapshot.*;
            mut_snapshot.deinit();
        }
    }

    /// Initialize minimal state for testing
    pub fn testInit(allocator: std.mem.Allocator) !AppState {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = try std.fs.cwd().realpath(".", &buf);

        return AppState{
            .audio_engine = try audio.AudioEngine.init(allocator),
            .file_browser = try FileBrowser.init(allocator, cwd),
            .preset_manager = try presets.PresetManager.init(allocator),
            .selected_channel = null,
            .last_error = null,
            .current_preset_name = null,
            .preset_snapshot = null,
            .pending_preset_name = null,
            .active_modal = modal.Modal.none(),
            .toast_queue = std.ArrayList(PendingToast){ .items = &.{}, .capacity = 0 },
            .allocator = allocator,
        };
    }

    /// Take a snapshot of current preset state for dirty tracking
    pub fn takeSnapshot(self: *AppState) !void {
        // Clear old snapshot if exists
        if (self.preset_snapshot) |*old| {
            var mut_old = old.*;
            mut_old.deinit();
        }

        // Create new snapshot
        var channels = try self.allocator.alloc(PresetSnapshot.ChannelSnapshot, self.audio_engine.channels.items.len);
        errdefer self.allocator.free(channels);

        for (self.audio_engine.channels.items, 0..) |channel, i| {
            channels[i] = .{
                .path = try self.allocator.dupe(u8, channel.file_path),
                .volume = channel.volume,
                .loop = channel.is_looping,
            };
        }

        self.preset_snapshot = PresetSnapshot{
            .channels = channels,
            .allocator = self.allocator,
        };
    }

    /// Check if current state differs from snapshot (preset is dirty)
    pub fn isPresetDirty(self: *const AppState) bool {
        const snapshot = self.preset_snapshot orelse return false;

        // Different number of channels = dirty
        if (self.audio_engine.channels.items.len != snapshot.channels.len) {
            return true;
        }

        // Compare each channel
        for (self.audio_engine.channels.items, snapshot.channels) |channel, snap| {
            if (!std.mem.eql(u8, channel.file_path, snap.path)) return true;
            if (channel.volume != snap.volume) return true;
            if (channel.is_looping != snap.loop) return true;
        }

        return false;
    }

    /// Load a preset by name, replacing current channels
    pub fn loadPresetByName(self: *AppState, preset_name: []const u8) !void {
        const preset = try self.preset_manager.load(preset_name);
        defer {
            var mut_p = preset;
            mut_p.deinit(self.preset_manager.allocator);
        }

        // Clear existing channels
        while (self.audio_engine.channels.items.len > 0) {
            try self.audio_engine.removeChannel(0);
        }

        // Load preset channels
        for (preset.channels) |ch_config| {
            const idx = self.audio_engine.addChannel(ch_config.path) catch continue;
            self.audio_engine.setVolume(idx, ch_config.volume) catch {};
            if (ch_config.loop) {
                self.audio_engine.toggleLoop(idx) catch {};
            }
        }

        // Update current preset name
        if (self.current_preset_name) |old| {
            self.allocator.free(old);
        }
        self.current_preset_name = try self.allocator.dupe(u8, preset.name);

        // Take snapshot for dirty tracking
        try self.takeSnapshot();
    }

    /// Save current channels as a preset
    pub fn saveCurrentAsPreset(self: *AppState, preset_name: []const u8) !void {
        // Create channel configs from current state
        const channels_slice = blk: {
            var list = std.ArrayList(presets.ChannelConfig){ .items = &.{}, .capacity = 0 };

            for (self.audio_engine.channels.items) |channel| {
                const path_copy = self.allocator.dupe(u8, channel.file_path) catch continue;
                list.append(self.allocator, .{
                    .path = path_copy,
                    .volume = channel.volume,
                    .loop = channel.is_looping,
                }) catch |e| {
                    return e;
                };
            }

            break :blk list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        };

        const name_copy = try self.allocator.dupe(u8, preset_name);

        const preset = presets.Preset{
            .name = name_copy,
            .channels = @constCast(channels_slice),
        };

        self.preset_manager.save(preset) catch |e| {
            // Clean up on error
            var mut_preset = preset;
            mut_preset.deinit(self.allocator);
            return e;
        };

        // Update current preset name
        // IMPORTANT: Dupe first before freeing, in case preset_name points to current_preset_name
        const new_name = try self.allocator.dupe(u8, preset_name);
        if (self.current_preset_name) |old| {
            self.allocator.free(old);
        }
        self.current_preset_name = new_name;

        // Take snapshot for dirty tracking
        try self.takeSnapshot();
    }

    /// Show a toast notification
    /// If a blocking modal is active, queue the toast for later
    pub fn showToast(self: *AppState, message: []const u8, level: modal.ToastLevel, duration_ms: i64) void {
        // If confirmation or info modal is active, queue the toast
        if (self.active_modal.modal_type == .confirmation or
            self.active_modal.modal_type == .info)
        {
            self.toast_queue.append(self.allocator, .{
                .message = message,
                .level = level,
                .duration_ms = duration_ms,
            }) catch return; // Silently fail if queue is full
            return;
        }

        // If another toast is active, queue this one
        if (self.active_modal.modal_type == .toast) {
            self.toast_queue.append(self.allocator, .{
                .message = message,
                .level = level,
                .duration_ms = duration_ms,
            }) catch return;
            return;
        }

        // Show immediately if no modal is active
        self.active_modal = modal.Modal.toast(message, level, duration_ms);
    }

    /// Process next queued toast if available
    /// Call this when modal dismisses or toast expires
    pub fn processToastQueue(self: *AppState) void {
        // Only process if no modal is currently active
        if (self.active_modal.isActive()) return;

        // Pop next toast from queue
        if (self.toast_queue.items.len > 0) {
            const pending = self.toast_queue.orderedRemove(0);
            self.active_modal = modal.Modal.toast(pending.message, pending.level, pending.duration_ms);
        }
    }

    /// Show a success toast (2 seconds)
    pub fn showSuccess(self: *AppState, message: []const u8) void {
        self.showToast(message, .success, 2000);
    }

    /// Show an error toast (3 seconds)
    pub fn showError(self: *AppState, message: []const u8) void {
        self.showToast(message, .error_level, 3000);
    }

    /// Show an info toast (2 seconds)
    pub fn showInfo(self: *AppState, message: []const u8) void {
        self.showToast(message, .info, 2000);
    }
};

pub fn createLayout(state: *AppState) []clay.RenderCommand {
    clay.beginLayout();

    // Compile-time channel number strings (1-9)
    const channel_numbers = [_][]const u8{ "1", "2", "3", "4", "5", "6", "7", "8", "9" };

    // Simple volume percentage strings - just use common values
    const volume_strs = [_][]const u8{ "0", "10", "20", "30", "40", "50", "60", "70", "80", "90", "100" };

    clay.UI()(.{
        .id = .ID("MainContent"),
        .layout = .{
            .direction = .top_to_bottom,
            .sizing = .grow,
            .padding = .all(16),
            // TODO add a child_gap here, it seems to interact weirdly with padding
        },
        .background_color = color_bg,
    })({
        clay.text("atmora - Ambient Audio Mixer", .{
            .font_size = 20,
            .color = color_text,
        });

        // Error display
        if (state.last_error) |err_msg| {
            clay.UI()(.{
                .id = .ID("ErrorPanel"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fit },
                    .padding = .all(8),
                },
                .background_color = color_error,
            })({
                clay.text("ERROR: ", .{
                    .font_size = 14,
                    .color = color_text,
                });
                clay.text(err_msg, .{
                    .font_size = 14,
                    .color = color_text,
                });
            });
        }

        clay.UI()(.{
            .id = .ID("ChannelsSection"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .padding = .all(12),
                .direction = .top_to_bottom,
            },
            .background_color = color_container,
        })({
            clay.text("Active Channels:", .{
                .font_size = 16,
                .color = color_text,
            });

            // Show current preset name if any
            if (state.current_preset_name) |preset_name| {
                clay.text("Preset: ", .{
                    .font_size = 11,
                    .color = color_text,
                });
                clay.text(preset_name, .{
                    .font_size = 11,
                    .color = color_accent1,
                });

                // Show dirty indicator if preset has unsaved changes
                if (state.isPresetDirty()) {
                    clay.text("[modified]", .{
                        .font_size = 11,
                        .color = color_warn,
                    });
                }
            }

            clay.UI()(.{
                .id = .ID("ChannelsContainer"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fit },
                    .direction = .top_to_bottom,
                },
            })({
                if (state.audio_engine.channels.items.len == 0) {
                    clay.text("  (no channels loaded - use file browser to add)", .{
                        .font_size = 12,
                        .color = color_text,
                    });
                } else {
                    clay.UI()(.{
                        .id = .ID("ChannelList"),
                        .layout = .{
                            .sizing = .{ .w = .grow, .h = .fit },
                            .direction = .top_to_bottom,
                        },
                    })({
                        for (state.audio_engine.channels.items, 0..) |channel, i| {
                            const is_selected = if (state.selected_channel) |sel| sel == i else false;
                            const bg_color = if (is_selected) color_accent1 else color_bg;

                            clay.UI()(.{
                                .id = .IDI("Channel", @intCast(i)),
                                .layout = .{
                                    .sizing = .{ .w = .grow, .h = .fit },
                                    .direction = .top_to_bottom,
                                },
                                .background_color = bg_color,
                            })({
                                // Channel number and filename (separate line)
                                clay.UI()(.{
                                    .id = .IDI("ChannelLabel", @intCast(i)),
                                    .layout = .{
                                        .sizing = .{ .w = .grow, .h = .fit },
                                        .direction = .left_to_right,
                                    },
                                })({
                                    clay.text("[", .{
                                        .font_size = 14,
                                        .color = color_text,
                                    });
                                    clay.text(channel_numbers[i], .{
                                        .font_size = 14,
                                        .color = color_text,
                                    });
                                    clay.text("] ", .{
                                        .font_size = 14,
                                        .color = color_text,
                                    });
                                    const basename = std.fs.path.basename(channel.file_path);
                                    clay.text(basename, .{
                                        .font_size = 14,
                                        .color = color_text,
                                    });
                                    clay.text("  ", .{
                                        .font_size = 14,
                                        .color = color_text,
                                    });
                                });

                                // Status indicators (separate line)
                                clay.UI()(.{
                                    .id = .IDI("ChannelStatus", @intCast(i)),
                                    .layout = .{
                                        .sizing = .{ .w = .grow, .h = .fit },
                                        .direction = .left_to_right,
                                    },
                                })({
                                    const vol_idx = channel.volume / 10; // 0-10 index
                                    clay.text("  Vol:", .{
                                        .font_size = 12,
                                        .color = color_text,
                                    });
                                    clay.text(volume_strs[vol_idx], .{
                                        .font_size = 12,
                                        .color = color_text,
                                    });
                                    clay.text("% ", .{
                                        .font_size = 12,
                                        .color = color_text,
                                    });

                                    const playing_str = if (channel.is_playing) "PLAY" else "STOP";
                                    clay.text(playing_str, .{
                                        .font_size = 12,
                                        .color = color_text,
                                    });

                                    if (channel.is_muted) {
                                        clay.text(" [MUTE]", .{
                                            .font_size = 12,
                                            .color = color_text,
                                        });
                                    }
                                    if (channel.is_solo) {
                                        clay.text(" [SOLO]", .{
                                            .font_size = 12,
                                            .color = color_text,
                                        });
                                    }
                                    if (channel.is_looping) {
                                        clay.text(" [LOOP]", .{
                                            .font_size = 12,
                                            .color = color_text,
                                        });
                                    }
                                });
                            });
                        }
                    });
                }
            });
        });

        clay.UI()(.{
            .id = .ID("BrowserSection"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .padding = .all(12),
                .direction = .top_to_bottom,
            },
            .background_color = color_container,
        })({
            clay.text("File Browser:", .{
                .font_size = 16,
                .color = color_text,
            });

            clay.text(state.file_browser.current_path, .{
                .font_size = 11,
                .color = color_text,
            });

            // Entries container with tight spacing
            clay.UI()(.{
                .id = .ID("BrowserEntries"),
                .layout = .{
                    .sizing = .{ .w = .grow, .h = .fit },
                    .direction = .top_to_bottom,
                },
            })({
                // Calculate visible window of entries
                const max_shown: usize = 5;
                const total_entries = state.file_browser.entries.items.len;

                if (total_entries == 0) {
                    clay.text("  (empty directory)", .{
                        .font_size = 12,
                        .color = color_text,
                    });
                } else {
                    // Calculate window to keep selection visible
                    const selected = state.file_browser.selected_index;
                    const window_start = if (total_entries <= max_shown)
                        0
                    else if (selected < max_shown / 2)
                        0
                    else if (selected >= total_entries - (max_shown / 2))
                        total_entries - max_shown
                    else
                        selected - (max_shown / 2);

                    const window_end = @min(window_start + max_shown, total_entries);

                    for (state.file_browser.entries.items[window_start..window_end], window_start..) |entry, i| {
                        const is_selected = (i == state.file_browser.selected_index);
                        const text_color = if (is_selected) color_accent1 else color_text;

                        clay.UI()(.{
                            .id = .IDI("BrowserEntry", @intCast(i)),
                            .layout = .{
                                .sizing = .{ .w = .grow, .h = .fit },
                                .direction = .left_to_right,
                            },
                        })({
                            // Selection indicator (always render, changes based on selection)
                            const prefix = if (is_selected) "> " else "  ";
                            clay.text(prefix, .{
                                .font_size = 12,
                                .color = text_color,
                            });

                            // Entry name
                            clay.text(entry.name, .{
                                .font_size = 12,
                                .color = text_color,
                            });

                            // Type marker (always render, different based on type)
                            const marker = if (entry.is_directory) "/" else if (entry.is_audio_file) "*" else "";
                            clay.text(marker, .{
                                .font_size = 12,
                                .color = text_color,
                            });
                        });
                    }

                    // Show scroll indicators only when needed
                    // For now, just show simple indicators without exact counts
                    if (total_entries > max_shown) {
                        const hidden_above = window_start;
                        const hidden_below = total_entries - window_end;

                        if (hidden_above > 0 and hidden_below > 0) {
                            clay.text("  (more above and below)", .{
                                .font_size = 11,
                                .color = color_text,
                            });
                        } else if (hidden_above > 0) {
                            clay.text("  (more above)", .{
                                .font_size = 11,
                                .color = color_text,
                            });
                        } else if (hidden_below > 0) {
                            clay.text("  (more below)", .{
                                .font_size = 11,
                                .color = color_text,
                            });
                        }
                    }
                } // End of else block for entries
            }); // End of BrowserEntries container
        }); // End of BrowserSection

        // Spacer to push controls to bottom
        clay.UI()(.{
            .id = .ID("Spacer"),
            .layout = .{
                .sizing = .{ .w = .fit, .h = .grow },
            },
        })({});

        clay.UI()(.{
            .id = .ID("InstructionsContainer"),
            .layout = .{
                .sizing = .{ .w = .grow, .h = .fit },
                .direction = .top_to_bottom,
            },
        })({
            clay.UI()(.{
                .id = .ID("Instructions"),
                .layout = .{
                    .sizing = .fit,
                    .padding = .all(10),
                    .direction = .top_to_bottom,
                },
            })({
                clay.text("Controls:", .{
                    .font_size = 14,
                    .color = color_accent1,
                });
                clay.text("  1-9: Select channel  Space: Play/Pause  +/-: Volume", .{
                    .font_size = 11,
                    .color = color_container,
                });
                clay.text("  M: Mute  S: Solo  L: Loop  D/Del: Delete channel", .{
                    .font_size = 11,
                    .color = color_container,
                });
                clay.text("  Up/Down: Navigate browser  Enter: Add file/Enter dir", .{
                    .font_size = 11,
                    .color = color_container,
                });
                clay.text("  Backspace: Parent dir  H: Toggle hidden files", .{
                    .font_size = 11,
                    .color = color_container,
                });
                clay.text("  P: Cycle presets  Ctrl+S: Save preset", .{
                    .font_size = 11,
                    .color = color_container,
                });
                clay.text("  Q or Ctrl+C: Quit", .{
                    .font_size = 11,
                    .color = color_container,
                });
            }); // End of Instructions
        }); // End of InstructionsContainer

        // Render modal overlay if active
        if (state.active_modal.isActive()) {
            if (state.active_modal.modal_type == .toast) {
                renderToast(&state.active_modal);
            } else {
                renderModal(&state.active_modal);
            }
        }
    });

    return clay.endLayout();
}

/// Render modal dialog overlay
fn renderModal(active_modal: *const modal.Modal) void {
    // Semi-transparent overlay background
    clay.UI()(.{
        .id = .ID("ModalOverlay"),
        .layout = .{
            .sizing = .grow,
            .direction = .top_to_bottom,
            .padding = .all(20),
        },
        .background_color = .{ 0, 0, 0, 180 }, // Semi-transparent black
    })(
        {
            // Centered modal box
            clay.UI()(.{
                .id = .ID("ModalBox"),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .all(16),
                    .direction = .top_to_bottom,
                },
                .background_color = color_container,
            })(
                {
                    // Title
                    if (active_modal.title.len > 0) {
                        clay.text(active_modal.title, .{
                            .font_size = 16,
                            .color = color_accent1,
                        });
                    }

                    // Message
                    clay.text(active_modal.message, .{
                        .font_size = 14,
                        .color = color_text,
                    });

                    // Buttons
                    clay.UI()(.{
                        .id = .ID("ModalButtons"),
                        .layout = .{
                            .sizing = .{ .w = .fit, .h = .fit },
                            .direction = .left_to_right,
                            .padding = .{ .top = 12 },
                        },
                    })(
                        {
                            switch (active_modal.modal_type) {
                                .confirmation => {
                                    // Confirm button
                                    const confirm_bg = if (active_modal.selected_button == 0) color_accent1 else color_bg;
                                    clay.UI()(.{
                                        .id = .ID("ConfirmButton"),
                                        .layout = .{
                                            .sizing = .{ .w = .fit, .h = .fit },
                                            .padding = .all(8),
                                        },
                                        .background_color = confirm_bg,
                                    })(
                                        {
                                            clay.text(active_modal.confirm_label, .{
                                                .font_size = 12,
                                                .color = color_text,
                                            });
                                        },
                                    );

                                    // Cancel button
                                    const cancel_bg = if (active_modal.selected_button == 1) color_accent1 else color_bg;
                                    clay.UI()(.{
                                        .id = .ID("CancelButton"),
                                        .layout = .{
                                            .sizing = .{ .w = .fit, .h = .fit },
                                            .padding = .all(8),
                                        },
                                        .background_color = cancel_bg,
                                    })(
                                        {
                                            clay.text(active_modal.cancel_label, .{
                                                .font_size = 12,
                                                .color = color_text,
                                            });
                                        },
                                    );
                                },
                                .info => {
                                    // OK button
                                    clay.UI()(.{
                                        .id = .ID("OKButton"),
                                        .layout = .{
                                            .sizing = .{ .w = .fit, .h = .fit },
                                            .padding = .all(8),
                                        },
                                        .background_color = color_accent1,
                                    })(
                                        {
                                            clay.text(active_modal.confirm_label, .{
                                                .font_size = 12,
                                                .color = color_text,
                                            });
                                        },
                                    );
                                },
                                .choice => {
                                    // Render choice buttons (2 or 3 options)
                                    const labels = [_][]const u8{
                                        active_modal.option1_label,
                                        active_modal.option2_label,
                                        active_modal.option3_label,
                                    };

                                    for (labels[0..active_modal.num_options], 0..) |label, i| {
                                        const btn_bg = if (active_modal.selected_button == i) color_accent1 else color_bg;
                                        const btn_id_str = switch (i) {
                                            0 => "ChoiceButton1",
                                            1 => "ChoiceButton2",
                                            2 => "ChoiceButton3",
                                            else => "ChoiceButton",
                                        };

                                        clay.UI()(.{
                                            .id = .ID(btn_id_str),
                                            .layout = .{
                                                .sizing = .{ .w = .fit, .h = .fit },
                                                .padding = .all(8),
                                            },
                                            .background_color = btn_bg,
                                        })(
                                            {
                                                clay.text(label, .{
                                                    .font_size = 12,
                                                    .color = color_text,
                                                });
                                            },
                                        );
                                    }
                                },
                                .none => {},
                                .toast => {
                                    // Toast doesn't have buttons, just message
                                },
                            }
                        },
                    );
                },
            );
        },
    );
}

/// Render toast notification (smaller, non-blocking style)
fn renderToast(active_modal: *const modal.Modal) void {
    // Determine color based on toast level
    const toast_bg = switch (active_modal.toast_level) {
        .success => color_success,
        .error_level => color_error,
        .warning => color_accent2,
        .info => color_accent1,
    };

    // Toast positioned at top, centered
    clay.UI()(.{
        .id = .ID("ToastOverlay"),
        .layout = .{
            .sizing = .{ .w = .grow, .h = .fit },
            .direction = .top_to_bottom,
            .padding = .all(16),
        },
    })(
        {
            // Toast box
            clay.UI()(.{
                .id = .ID("ToastBox"),
                .layout = .{
                    .sizing = .{ .w = .fit, .h = .fit },
                    .padding = .all(12),
                },
                .background_color = toast_bg,
            })(
                {
                    clay.text(active_modal.message, .{
                        .font_size = 12,
                        .color = color_text,
                    });
                },
            );
        },
    );
}
// ============================================================================
// Tests

const testing = std.testing;

test "PresetSnapshot: basic creation and cleanup" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var snapshot = PresetSnapshot{
        .channels = try allocator.alloc(PresetSnapshot.ChannelSnapshot, 2),
        .allocator = allocator,
    };

    snapshot.channels[0] = .{
        .path = try allocator.dupe(u8, "/path/to/file1.mp3"),
        .volume = 80,
        .loop = true,
    };
    snapshot.channels[1] = .{
        .path = try allocator.dupe(u8, "/path/to/file2.mp3"),
        .volume = 60,
        .loop = false,
    };

    try testing.expectEqual(@as(usize, 2), snapshot.channels.len);
    try testing.expectEqualStrings("/path/to/file1.mp3", snapshot.channels[0].path);
    try testing.expectEqual(@as(u8, 80), snapshot.channels[0].volume);
    try testing.expectEqual(true, snapshot.channels[0].loop);

    snapshot.deinit();
}

// NOTE: More comprehensive tests for dirty state tracking require test audio files
// and a working audio engine initialization. These tests can be added once test
// assets are available. Tests would cover:
// - isPresetDirty returns false with no snapshot
// - isPresetDirty detects volume changes
// - isPresetDirty detects loop changes
// - isPresetDirty detects channel additions/removals
// - takeSnapshot updates existing snapshot
