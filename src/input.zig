const std = @import("std");
const clay = @import("zclay");
const tb = @import("termbox.zig");
const ui = @import("ui.zig");
const presets = @import("presets.zig");
const modal = @import("modal.zig");

/// Handle terminal events
pub fn handleEvents(state: *ui.AppState, should_quit: *bool) !void {
    // Check if toast has expired (even if no events)
    if (state.active_modal.checkExpiry()) {
        // Toast expired, process next one from queue
        state.processToastQueue();
    }

    var evt: tb.Event = undefined;
    const ms_to_wait = 0;
    const err = tb.peekEvent(&evt, ms_to_wait);

    switch (err) {
        tb.ERR_NO_EVENT => {},
        tb.ERR_POLL => {
            if (tb.lastErrno() != @intFromEnum(std.posix.E.INTR)) {
                return error.EventPollFailed;
            }
        },
        tb.OK => {
            switch (evt.type) {
                tb.EVENT_RESIZE => {
                    clay.setLayoutDimensions(.{
                        .w = tb.width(),
                        .h = tb.height(),
                    });
                },
                tb.EVENT_KEY => {
                    // If modal is active, handle modal input first
                    if (state.active_modal.isActive()) {
                        const action = state.active_modal.handleInput(evt.key, evt.ch);
                        const context = state.active_modal.context;
                        switch (action) {
                            .confirm => {
                                // Handle confirmation based on modal context
                                switch (context) {
                                    .quit_confirm => {
                                        should_quit.* = true;
                                    },
                                    .delete_preset => {
                                        if (state.current_preset_name) |preset_name| {
                                            state.preset_manager.delete(preset_name) catch |e| {
                                                state.showError(@errorName(e));
                                                state.active_modal.dismiss();
                                                return;
                                            };
                                            // Clear current preset name
                                            state.preset_manager.allocator.free(preset_name);
                                            state.current_preset_name = null;
                                            state.showSuccess("Preset deleted");
                                        }
                                    },
                                    .load_confirm => {
                                        if (state.pending_preset_name) |preset_name| {
                                            state.loadPresetByName(preset_name) catch |e| {
                                                state.showError(@errorName(e));
                                            };
                                            state.preset_manager.allocator.free(preset_name);
                                            state.pending_preset_name = null;
                                        }
                                    },
                                    .save_choice => {
                                        // Will handle when we add save choice modal
                                    },
                                    .none => {},
                                }
                                state.active_modal.dismiss();
                                state.processToastQueue(); // Process queued toasts after modal closes
                            },
                            .cancel => {
                                // Clean up pending preset name if present
                                if (state.pending_preset_name) |name| {
                                    state.preset_manager.allocator.free(name);
                                    state.pending_preset_name = null;
                                }
                                state.active_modal.dismiss();
                                state.processToastQueue(); // Process queued toasts after modal closes
                            },
                            .option1, .option2, .option3 => {
                                // Handle choice modal options based on context
                                switch (context) {
                                    .save_choice => {
                                        switch (action) {
                                            .option1 => {
                                                // Overwrite existing preset
                                                if (state.current_preset_name) |preset_name| {
                                                    state.saveCurrentAsPreset(preset_name) catch |e| {
                                                        state.showError(@errorName(e));
                                                        state.active_modal.dismiss();
                                                        return;
                                                    };
                                                    state.showSuccess("Preset saved!");
                                                }
                                            },
                                            .option2 => {
                                                // Save as new preset with timestamp
                                                const timestamp = std.time.timestamp();
                                                var name_buf: [64]u8 = undefined;
                                                const preset_name = std.fmt.bufPrint(&name_buf, "preset_{d}", .{timestamp}) catch "preset_unknown";

                                                state.saveCurrentAsPreset(preset_name) catch |e| {
                                                    state.showError(@errorName(e));
                                                    state.active_modal.dismiss();
                                                    return;
                                                };
                                                state.showSuccess("Preset saved!");
                                            },
                                            .option3 => {
                                                // Cancel - do nothing
                                            },
                                            else => {},
                                        }
                                    },
                                    else => {},
                                }
                                state.active_modal.dismiss();
                                state.processToastQueue();
                            },
                            .none => {
                                // Still in modal, continue
                            },
                        }
                        return; // Don't process other input while modal is active
                    }

                    // Clear error on new input
                    state.last_error = null;

                    if (evt.key == tb.KEY_CTRL_C or evt.ch == 'q' or evt.ch == 'Q') {
                        // Check if there's a dirty preset before quitting
                        if (state.current_preset_name != null and state.isPresetDirty()) {
                            state.active_modal = modal.Modal.confirmation(
                                "Unsaved Changes",
                                "You have unsaved changes. Quit anyway?",
                                "Quit",
                                "Cancel",
                                .quit_confirm,
                            );
                        } else {
                            should_quit.* = true;
                        }
                    }
                    // Save current state as preset
                    else if (evt.key == tb.KEY_CTRL_S) {
                        // Check if we have a loaded preset that's dirty
                        if (state.current_preset_name != null and state.isPresetDirty()) {
                            // Show choice modal: Overwrite, Save As New, Cancel
                            state.active_modal = modal.Modal.choice(
                                "Save Changes",
                                "Overwrite existing preset or save as new?",
                                "Overwrite",
                                "Save As New",
                                "Cancel",
                                .save_choice,
                            );
                        } else {
                            // Normal save logic - create new preset
                        // Create preset from current state
                        const channels_slice = blk: {
                            var list = std.ArrayList(presets.ChannelConfig){ .items = &.{}, .capacity = 0 };

                            for (state.audio_engine.channels.items) |channel| {
                                const path_copy = state.preset_manager.allocator.dupe(u8, channel.file_path) catch continue;
                                list.append(state.preset_manager.allocator, .{
                                    .path = path_copy,
                                    .volume = channel.volume,
                                    .loop = channel.is_looping,
                                }) catch |e| {
                                    state.last_error = @errorName(e);
                                    break :blk &[_]presets.ChannelConfig{};
                                };
                            }

                            break :blk list.toOwnedSlice(state.preset_manager.allocator) catch &[_]presets.ChannelConfig{};
                        };

                        if (channels_slice.len > 0) {
                            // Generate timestamp-based name
                            const timestamp = std.time.timestamp();
                            var name_buf: [64]u8 = undefined;
                            const preset_name = std.fmt.bufPrint(&name_buf, "preset_{d}", .{timestamp}) catch "preset_unknown";
                            const name_copy = state.preset_manager.allocator.dupe(u8, preset_name) catch blk: {
                                state.last_error = "OutOfMemory";
                                break :blk null;
                            };

                            if (name_copy) |name| {
                                const preset = presets.Preset{
                                    .name = name,
                                    .channels = @constCast(channels_slice),
                                };

                                state.preset_manager.save(preset) catch |e| {
                                    state.showError(@errorName(e));
                                    // Clean up on error
                                    var mut_preset = preset;
                                    mut_preset.deinit(state.preset_manager.allocator);
                                    return;
                                };

                                // Update current preset name
                                if (state.current_preset_name) |old| {
                                    state.preset_manager.allocator.free(old);
                                }
                                state.current_preset_name = state.preset_manager.allocator.dupe(u8, name) catch null;

                                // Take snapshot for dirty tracking
                                state.takeSnapshot() catch {};

                                state.showSuccess("Preset saved!");
                            }
                        }
                        }
                    }
                    // Unselect channel with Escape
                    else if (evt.key == tb.KEY_ESC) {
                        state.selected_channel = null;
                    }
                    // Channel selection (1-9) - toggle if pressing same number
                    else if (evt.ch >= '1' and evt.ch <= '9') {
                        const index = @as(usize, evt.ch - '1');
                        if (index < state.audio_engine.channels.items.len) {
                            // Toggle: if already selected, unselect; otherwise select
                            if (state.selected_channel) |current| {
                                if (current == index) {
                                    state.selected_channel = null;
                                } else {
                                    state.selected_channel = index;
                                }
                            } else {
                                state.selected_channel = index;
                            }
                        }
                    }
                    // Play/Pause
                    else if (evt.ch == ' ') {
                        if (state.selected_channel) |idx| {
                            const channel = &state.audio_engine.channels.items[idx];
                            if (channel.is_playing) {
                                state.audio_engine.stopChannel(idx) catch |e| {
                                    state.last_error = @errorName(e);
                                };
                            } else {
                                state.audio_engine.playChannel(idx) catch |e| {
                                    state.last_error = @errorName(e);
                                };
                            }
                        }
                    }
                    // Volume up
                    else if (evt.ch == '+' or evt.ch == '=') {
                        if (state.selected_channel) |idx| {
                            const channel = &state.audio_engine.channels.items[idx];
                            const new_vol = @min(100, channel.volume +| 10); // +| for saturating add
                            state.audio_engine.setVolume(idx, new_vol) catch |e| {
                                state.last_error = @errorName(e);
                            };
                        }
                    }
                    // Volume down
                    else if (evt.ch == '-' or evt.ch == '_') {
                        if (state.selected_channel) |idx| {
                            const channel = &state.audio_engine.channels.items[idx];
                            const new_vol = channel.volume -| 10; // -| for saturating subtract
                            state.audio_engine.setVolume(idx, new_vol) catch |e| {
                                state.last_error = @errorName(e);
                            };
                        }
                    }
                    // Toggle mute
                    else if (evt.ch == 'm' or evt.ch == 'M') {
                        if (state.selected_channel) |idx| {
                            state.audio_engine.toggleMute(idx) catch |e| {
                                state.last_error = @errorName(e);
                            };
                        }
                    }
                    // Toggle solo
                    else if (evt.ch == 's' or evt.ch == 'S') {
                        if (state.selected_channel) |idx| {
                            state.audio_engine.toggleSolo(idx) catch |e| {
                                state.last_error = @errorName(e);
                            };
                        }
                    }
                    // Toggle loop
                    else if (evt.ch == 'l' or evt.ch == 'L') {
                        if (state.selected_channel) |idx| {
                            state.audio_engine.toggleLoop(idx) catch |e| {
                                state.last_error = @errorName(e);
                            };
                        }
                    }
                    // Delete channel
                    else if (evt.ch == 'd' or evt.ch == 'D' or evt.key == tb.KEY_DELETE) {
                        if (state.selected_channel) |idx| {
                            state.audio_engine.removeChannel(idx) catch |e| {
                                state.last_error = @errorName(e);
                            };
                            // Adjust selection
                            if (state.audio_engine.channels.items.len == 0) {
                                state.selected_channel = null;
                            } else if (idx >= state.audio_engine.channels.items.len) {
                                state.selected_channel = state.audio_engine.channels.items.len - 1;
                            }
                        }
                    }
                    // Preset management
                    else if (evt.ch == 'p' or evt.ch == 'P') {
                        // Cycle through presets
                        const preset_names = state.preset_manager.listPresets() catch |e| blk: {
                            state.last_error = @errorName(e);
                            break :blk &[_][]const u8{};
                        };
                        defer {
                            for (preset_names) |name| {
                                state.preset_manager.allocator.free(name);
                            }
                            state.preset_manager.allocator.free(preset_names);
                        }

                        if (preset_names.len > 0) {
                            // Find current preset index
                            var next_idx: usize = 0;
                            if (state.current_preset_name) |current| {
                                for (preset_names, 0..) |name, i| {
                                    if (std.mem.eql(u8, name, current)) {
                                        next_idx = (i + 1) % preset_names.len;
                                        break;
                                    }
                                }
                            }

                            const next_preset_name = preset_names[next_idx];

                            // Check if dirty before loading
                            if (state.current_preset_name != null and state.isPresetDirty()) {
                                // Store pending preset name and show confirmation
                                if (state.pending_preset_name) |old| {
                                    state.preset_manager.allocator.free(old);
                                }
                                state.pending_preset_name = state.preset_manager.allocator.dupe(u8, next_preset_name) catch null;

                                state.active_modal = modal.Modal.confirmation(
                                    "Unsaved Changes",
                                    "You have unsaved changes. Load preset anyway?",
                                    "Load",
                                    "Cancel",
                                    .load_confirm,
                                );
                            } else {
                                // Load immediately if not dirty
                                state.loadPresetByName(next_preset_name) catch |e| {
                                    state.last_error = @errorName(e);
                                };
                            }
                        }
                    }
                    // Delete current preset (with confirmation)
                    else if (evt.ch == 'x' or evt.ch == 'X') {
                        if (state.current_preset_name) |preset_name| {
                            // Show confirmation modal
                            state.active_modal = modal.Modal.confirmation(
                                "Delete Preset",
                                preset_name,
                                "Delete",
                                "Cancel",
                                .delete_preset,
                            );
                        }
                    }
                    // File browser navigation
                    else if (evt.key == tb.KEY_ARROW_UP) {
                        state.file_browser.selectPrevious();
                    } else if (evt.key == tb.KEY_ARROW_DOWN) {
                        state.file_browser.selectNext();
                    } else if (evt.key == tb.KEY_ENTER) {
                        // Activate selected entry (enter dir or add file)
                        if (state.file_browser.activateSelected()) |maybe_path| {
                            if (maybe_path) |path| {
                                defer state.file_browser.allocator.free(path);
                                // Add as channel
                                const idx = state.audio_engine.addChannel(path) catch |e| blk: {
                                    state.last_error = @errorName(e);
                                    break :blk null;
                                };
                                if (idx) |channel_idx| {
                                    state.selected_channel = channel_idx;
                                }
                            }
                            // If null, we navigated to a directory
                        } else |e| {
                            state.last_error = @errorName(e);
                        }
                    } else if (evt.key == tb.KEY_BACKSPACE or evt.key == tb.KEY_BACKSPACE2) {
                        state.file_browser.navigateUp() catch |e| {
                            state.last_error = @errorName(e);
                        };
                    } else if (evt.ch == 'h' or evt.ch == 'H') {
                        state.file_browser.toggleHidden() catch |e| {
                            state.last_error = @errorName(e);
                        };
                    }
                },
                tb.EVENT_MOUSE => {
                    const mouse_pos = clay.Vector2{
                        .x = @as(f32, @floatFromInt(evt.x)) * tb.cellWidth(),
                        .y = @as(f32, @floatFromInt(evt.y)) * tb.cellHeight(),
                    };

                    const is_pressed = switch (evt.key) {
                        tb.KEY_MOUSE_LEFT => true,
                        else => false,
                    };

                    clay.setPointerState(mouse_pos, is_pressed);
                },
                else => {},
            }
        },
        else => {},
    }
}
