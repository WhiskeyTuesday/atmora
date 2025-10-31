const std = @import("std");

/// Type of modal dialog
pub const ModalType = enum {
    none, // No modal active
    confirmation, // Yes/No confirmation dialog
    info, // Information message with OK button
    toast, // Auto-dismissing notification (success, info, warning, error)
    choice, // Multiple choice dialog (up to 3 options)
    // Future: input, list_select, etc.
};

/// Toast notification severity
pub const ToastLevel = enum {
    info,
    success,
    warning,
    error_level, // Named error_level to avoid conflict with error types
};

/// Button actions for modals
pub const ModalAction = enum {
    none,
    confirm, // User confirmed (Yes, OK, etc.)
    cancel, // User cancelled (No, Cancel, Esc)
    option1, // First choice option
    option2, // Second choice option
    option3, // Third choice option
};

/// Context for modal actions (what triggered the modal)
pub const ModalContext = enum {
    none,
    quit_confirm, // Confirming quit with unsaved changes
    load_confirm, // Confirming load preset with unsaved changes
    delete_preset, // Confirming delete preset
    save_choice, // Choosing how to save dirty preset
};

/// Modal dialog state
pub const Modal = struct {
    modal_type: ModalType,
    title: []const u8,
    message: []const u8,

    // For confirmation dialogs
    confirm_label: []const u8, // e.g., "Delete", "Yes", "OK"
    cancel_label: []const u8, // e.g., "Cancel", "No"

    // For choice dialogs (up to 3 options)
    option1_label: []const u8,
    option2_label: []const u8,
    option3_label: []const u8,
    num_options: u8, // Number of options in choice dialog (2 or 3)

    // For toast notifications
    toast_level: ToastLevel,
    expire_time_ms: ?i64, // Milliseconds timestamp when toast should auto-dismiss (null = never)

    // Context for handling modal actions
    context: ModalContext,

    // Internal state
    selected_button: u8, // Index of selected button

    pub fn none() Modal {
        return Modal{
            .modal_type = .none,
            .title = "",
            .message = "",
            .confirm_label = "",
            .cancel_label = "",
            .option1_label = "",
            .option2_label = "",
            .option3_label = "",
            .num_options = 0,
            .toast_level = .info,
            .expire_time_ms = null,
            .context = .none,
            .selected_button = 0,
        };
    }

    pub fn confirmation(title: []const u8, message: []const u8, confirm_label: []const u8, cancel_label: []const u8, context: ModalContext) Modal {
        return Modal{
            .modal_type = .confirmation,
            .title = title,
            .message = message,
            .confirm_label = confirm_label,
            .cancel_label = cancel_label,
            .option1_label = "",
            .option2_label = "",
            .option3_label = "",
            .num_options = 0,
            .toast_level = .info,
            .expire_time_ms = null,
            .context = context,
            .selected_button = 0, // Default to cancel for safety
        };
    }

    pub fn info(title: []const u8, message: []const u8) Modal {
        return Modal{
            .modal_type = .info,
            .title = title,
            .message = message,
            .confirm_label = "OK",
            .cancel_label = "",
            .option1_label = "",
            .option2_label = "",
            .option3_label = "",
            .num_options = 0,
            .toast_level = .info,
            .expire_time_ms = null,
            .context = .none,
            .selected_button = 0,
        };
    }

    pub fn toast(message: []const u8, level: ToastLevel, duration_ms: i64) Modal {
        const current_time = std.time.milliTimestamp();
        return Modal{
            .modal_type = .toast,
            .title = "",
            .message = message,
            .confirm_label = "",
            .cancel_label = "",
            .option1_label = "",
            .option2_label = "",
            .option3_label = "",
            .num_options = 0,
            .toast_level = level,
            .expire_time_ms = current_time + duration_ms,
            .context = .none,
            .selected_button = 0,
        };
    }

    pub fn choice(title: []const u8, message: []const u8, opt1: []const u8, opt2: []const u8, opt3: []const u8, context: ModalContext) Modal {
        return Modal{
            .modal_type = .choice,
            .title = title,
            .message = message,
            .confirm_label = "",
            .cancel_label = "",
            .option1_label = opt1,
            .option2_label = opt2,
            .option3_label = opt3,
            .num_options = if (opt3.len > 0) 3 else 2,
            .toast_level = .info,
            .expire_time_ms = null,
            .context = context,
            .selected_button = 0,
        };
    }

    pub fn isActive(self: *const Modal) bool {
        return self.modal_type != .none;
    }

    pub fn dismiss(self: *Modal) void {
        self.modal_type = .none;
    }

    /// Check if toast has expired and auto-dismiss if needed
    /// Returns true if toast was dismissed
    pub fn checkExpiry(self: *Modal) bool {
        if (self.modal_type != .toast) return false;
        if (self.expire_time_ms) |expire_time| {
            const current_time = std.time.milliTimestamp();
            if (current_time >= expire_time) {
                self.dismiss();
                return true;
            }
        }
        return false;
    }

    /// Handle keyboard input for modal
    /// Returns the action taken (confirm, cancel, or none if still in modal)
    pub fn handleInput(self: *Modal, key: u16, ch: u32) ModalAction {
        switch (self.modal_type) {
            .confirmation => {
                // Tab or arrow keys switch between buttons
                if (key == 0x09 or ch == '\t') { // Tab
                    self.selected_button = if (self.selected_button == 0) 1 else 0;
                    return .none;
                }

                // Arrow keys
                if (key == (0xFFFF - 20) or key == (0xFFFF - 21)) { // Left/Right arrows
                    self.selected_button = if (self.selected_button == 0) 1 else 0;
                    return .none;
                }

                // Enter confirms selected button
                if (key == 0x0d or ch == '\n' or ch == '\r') { // Enter
                    return if (self.selected_button == 0) .confirm else .cancel;
                }

                // Escape always cancels
                if (key == 0x1b) { // Escape
                    return .cancel;
                }

                // Y/N shortcuts
                if (ch == 'y' or ch == 'Y') {
                    return .confirm;
                }
                if (ch == 'n' or ch == 'N') {
                    return .cancel;
                }

                return .none;
            },

            .info => {
                // Any key dismisses info modal
                if (key == 0x0d or key == 0x1b or ch == ' ') {
                    return .confirm;
                }
                return .none;
            },

            .toast => {
                // Any key dismisses toast (or wait for auto-dismiss)
                if (key != 0 or ch != 0) {
                    return .confirm;
                }
                return .none;
            },

            .choice => {
                // Tab or arrow keys cycle through options
                if (key == 0x09 or ch == '\t' or key == (0xFFFF - 21)) { // Tab or Right arrow
                    self.selected_button = (self.selected_button + 1) % self.num_options;
                    return .none;
                }
                if (key == (0xFFFF - 20)) { // Left arrow
                    if (self.selected_button == 0) {
                        self.selected_button = self.num_options - 1;
                    } else {
                        self.selected_button -= 1;
                    }
                    return .none;
                }

                // Enter confirms selected option
                if (key == 0x0d or ch == '\n' or ch == '\r') { // Enter
                    return switch (self.selected_button) {
                        0 => .option1,
                        1 => .option2,
                        2 => .option3,
                        else => .none,
                    };
                }

                // Escape cancels (returns last option which should be "Cancel")
                if (key == 0x1b) { // Escape
                    return switch (self.num_options) {
                        2 => .option2,
                        3 => .option3,
                        else => .none,
                    };
                }

                // Number keys as shortcuts (1, 2, 3)
                if (ch == '1' and self.num_options >= 1) return .option1;
                if (ch == '2' and self.num_options >= 2) return .option2;
                if (ch == '3' and self.num_options >= 3) return .option3;

                return .none;
            },

            .none => return .none,
        }
    }
};

// ============================================================================
// Tests

const testing = std.testing;

test "Modal: confirmation dialog creation" {
    const m = Modal.confirmation("Delete?", "Are you sure?", "Yes", "No", .none);
    try testing.expectEqual(ModalType.confirmation, m.modal_type);
    try testing.expectEqualStrings("Delete?", m.title);
    try testing.expectEqualStrings("Are you sure?", m.message);
    try testing.expect(m.isActive());
}

test "Modal: toast creation with timer" {
    const m = Modal.toast("Success!", .success, 2000);
    try testing.expectEqual(ModalType.toast, m.modal_type);
    try testing.expectEqualStrings("Success!", m.message);
    try testing.expectEqual(ToastLevel.success, m.toast_level);
    try testing.expect(m.expire_time_ms != null);
}

test "Modal: toast expiry" {
    // Create toast that expired 1 second ago
    const past_time = std.time.milliTimestamp() - 1000;
    var m = Modal{
        .modal_type = .toast,
        .title = "",
        .message = "Test",
        .confirm_label = "",
        .cancel_label = "",
        .option1_label = "",
        .option2_label = "",
        .option3_label = "",
        .num_options = 0,
        .toast_level = .info,
        .expire_time_ms = past_time,
        .context = .none,
        .selected_button = 0,
    };
    try testing.expect(m.isActive());

    const expired = m.checkExpiry();
    try testing.expect(expired);
    try testing.expect(!m.isActive());
}

test "Modal: confirmation input handling" {
    var m = Modal.confirmation("Test", "Message", "OK", "Cancel", .none);

    // Y should confirm
    const action1 = m.handleInput(0, 'y');
    try testing.expectEqual(ModalAction.confirm, action1);

    // N should cancel
    var m2 = Modal.confirmation("Test", "Message", "OK", "Cancel", .none);
    const action2 = m2.handleInput(0, 'n');
    try testing.expectEqual(ModalAction.cancel, action2);

    // Escape should cancel
    var m3 = Modal.confirmation("Test", "Message", "OK", "Cancel", .none);
    const action3 = m3.handleInput(0x1b, 0);
    try testing.expectEqual(ModalAction.cancel, action3);
}

test "Modal: toast dismisses on any key" {
    var m = Modal.toast("Test", .info, 5000);
    try testing.expect(m.isActive());

    const action = m.handleInput(0, 'x');
    try testing.expectEqual(ModalAction.confirm, action);
}

test "Modal: none state" {
    const m = Modal.none();
    try testing.expectEqual(ModalType.none, m.modal_type);
    try testing.expect(!m.isActive());
}
