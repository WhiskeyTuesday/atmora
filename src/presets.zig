const std = @import("std");

/// Represents a single channel configuration in a preset
pub const ChannelConfig = struct {
    path: []const u8, // Relative to project root
    volume: u8, // 0 - 100
    loop: bool,
};

/// Represents a complete preset configuration
pub const Preset = struct {
    name: []const u8,
    channels: []ChannelConfig,

    pub fn deinit(self: *Preset, allocator: std.mem.Allocator) void {
        // Free channel configs
        for (self.channels) |channel| {
            allocator.free(channel.path);
        }
        allocator.free(self.channels);
        allocator.free(self.name);
    }
};

/// Manages saving and loading presets
pub const PresetManager = struct {
    allocator: std.mem.Allocator,
    presets_dir: []const u8, // Owned by manager

    /// Initialize preset manager with default directory (~/.config/atmora/presets/)
    pub fn init(allocator: std.mem.Allocator) !PresetManager {
        const presets_dir = try getDefaultPresetsDir(allocator);
        errdefer allocator.free(presets_dir);

        // Create directory if it doesn't exist
        std.fs.cwd().makePath(presets_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK, directory exists
            else => return err,
        };

        return PresetManager{
            .allocator = allocator,
            .presets_dir = presets_dir,
        };
    }

    /// Initialize with custom presets directory
    pub fn initWithDir(allocator: std.mem.Allocator, dir_path: []const u8) !PresetManager {
        const owned_dir = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned_dir);

        // Create directory if it doesn't exist
        std.fs.cwd().makePath(owned_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {}, // OK, directory exists
            else => return err,
        };

        return PresetManager{
            .allocator = allocator,
            .presets_dir = owned_dir,
        };
    }

    pub fn deinit(self: *PresetManager) void {
        self.allocator.free(self.presets_dir);
    }

    /// Save a preset to disk
    pub fn save(self: *PresetManager, preset: Preset) !void {
        // Build full path
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{preset.name});
        defer self.allocator.free(filename);

        const full_path = try std.fs.path.join(self.allocator, &.{ self.presets_dir, filename });
        defer self.allocator.free(full_path);

        // Serialize to JSON
        const json_string = try std.json.Stringify.valueAlloc(self.allocator, preset, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json_string);

        const file = try std.fs.cwd().createFile(full_path, .{});
        defer file.close();

        try file.writeAll(json_string);
    }

    /// Load a preset from disk by name
    pub fn load(self: *PresetManager, name: []const u8) !Preset {
        // Build full path
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{name});
        defer self.allocator.free(filename);

        const full_path = try std.fs.path.join(self.allocator, &.{ self.presets_dir, filename });
        defer self.allocator.free(full_path);

        // Read file
        const file = try std.fs.cwd().openFile(full_path, .{});
        defer file.close();

        const file_size = try file.getEndPos();
        const buffer = try self.allocator.alloc(u8, file_size);
        defer self.allocator.free(buffer);

        _ = try file.readAll(buffer);

        // Parse JSON
        const parsed = try std.json.parseFromSlice(
            Preset,
            self.allocator,
            buffer,
            .{ .allocate = .alloc_always },
        );
        // Note: Caller owns the parsed data and must call deinit on the preset
        defer parsed.deinit();

        // Clone the preset data so it persists after parsed.deinit()
        var channels = try self.allocator.alloc(ChannelConfig, parsed.value.channels.len);
        for (parsed.value.channels, 0..) |channel, i| {
            channels[i] = .{
                .path = try self.allocator.dupe(u8, channel.path),
                .volume = channel.volume,
                .loop = channel.loop,
            };
        }

        return Preset{
            .name = try self.allocator.dupe(u8, parsed.value.name),
            .channels = channels,
        };
    }

    /// List all available preset names (without .json extension)
    pub fn listPresets(self: *PresetManager) ![][]const u8 {
        var dir = try std.fs.cwd().openDir(self.presets_dir, .{ .iterate = true });
        defer dir.close();

        var preset_names = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        errdefer {
            for (preset_names.items) |name| {
                self.allocator.free(name);
            }
            preset_names.deinit(self.allocator);
        }

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            // Check for .json extension
            if (std.mem.endsWith(u8, entry.name, ".json")) {
                // Remove .json extension
                const name_without_ext = entry.name[0 .. entry.name.len - 5];
                const owned_name = try self.allocator.dupe(u8, name_without_ext);
                try preset_names.append(self.allocator, owned_name);
            }
        }

        return preset_names.toOwnedSlice(self.allocator);
    }

    /// Delete a preset by name
    pub fn delete(self: *PresetManager, name: []const u8) !void {
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.json", .{name});
        defer self.allocator.free(filename);

        const full_path = try std.fs.path.join(self.allocator, &.{ self.presets_dir, filename });
        defer self.allocator.free(full_path);

        try std.fs.cwd().deleteFile(full_path);
    }
};

/// Get default presets directory (~/.config/atmora/presets/)
fn getDefaultPresetsDir(allocator: std.mem.Allocator) ![]const u8 {
    // Get home directory
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;

    // Build path
    return try std.fs.path.join(allocator, &.{ home, ".config", "atmora", "presets" });
}

// ============================================================================
// Tests
// ============================================================================

test "PresetManager init/deinit" {
    const allocator = std.testing.allocator;

    // Use a temporary directory for testing
    const test_dir = "zig-cache/test-presets";
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var manager = try PresetManager.initWithDir(allocator, test_dir);
    defer manager.deinit();

    // Verify directory was created
    var dir = try std.fs.cwd().openDir(test_dir, .{});
    dir.close();
}

test "Save and load preset" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-presets-save-load";
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var manager = try PresetManager.initWithDir(allocator, test_dir);
    defer manager.deinit();

    // Create a test preset
    var channels = try allocator.alloc(ChannelConfig, 2);
    channels[0] = .{ .path = try allocator.dupe(u8, "sounds/rain.mp3"), .volume = 80, .loop = true };
    channels[1] = .{ .path = try allocator.dupe(u8, "sounds/fire.ogg"), .volume = 50, .loop = true };

    var preset = Preset{
        .name = try allocator.dupe(u8, "cozy"),
        .channels = channels,
    };
    defer preset.deinit(allocator);

    // Save preset
    try manager.save(preset);

    // Load preset back
    var loaded = try manager.load("cozy");
    defer loaded.deinit(allocator);

    // Verify data
    try std.testing.expectEqualStrings("cozy", loaded.name);
    try std.testing.expectEqual(@as(usize, 2), loaded.channels.len);
    try std.testing.expectEqualStrings("sounds/rain.mp3", loaded.channels[0].path);
    try std.testing.expectEqual(@as(u8, 80), loaded.channels[0].volume);
    try std.testing.expectEqual(true, loaded.channels[0].loop);
}

test "List presets" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-presets-list";
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var manager = try PresetManager.initWithDir(allocator, test_dir);
    defer manager.deinit();

    // Create multiple test presets
    const preset_names = [_][]const u8{ "rain", "forest", "cafe" };
    for (preset_names) |name| {
        var channels = try allocator.alloc(ChannelConfig, 1);
        channels[0] = .{ .path = try allocator.dupe(u8, "test.mp3"), .volume = 1.0, .loop = true };

        var preset = Preset{
            .name = try allocator.dupe(u8, name),
            .channels = channels,
        };
        defer preset.deinit(allocator);

        try manager.save(preset);
    }

    // List presets
    const listed = try manager.listPresets();
    defer {
        for (listed) |name| {
            allocator.free(name);
        }
        allocator.free(listed);
    }

    // Verify count
    try std.testing.expectEqual(@as(usize, 3), listed.len);

    // Verify names (order may vary)
    var found_rain = false;
    var found_forest = false;
    var found_cafe = false;
    for (listed) |name| {
        if (std.mem.eql(u8, name, "rain")) found_rain = true;
        if (std.mem.eql(u8, name, "forest")) found_forest = true;
        if (std.mem.eql(u8, name, "cafe")) found_cafe = true;
    }
    try std.testing.expect(found_rain);
    try std.testing.expect(found_forest);
    try std.testing.expect(found_cafe);
}

test "Delete preset" {
    const allocator = std.testing.allocator;

    const test_dir = "zig-cache/test-presets-delete";
    std.fs.cwd().deleteTree(test_dir) catch {};
    defer std.fs.cwd().deleteTree(test_dir) catch {};

    var manager = try PresetManager.initWithDir(allocator, test_dir);
    defer manager.deinit();

    // Create a test preset
    var channels = try allocator.alloc(ChannelConfig, 1);
    channels[0] = .{ .path = try allocator.dupe(u8, "test.mp3"), .volume = 1.0, .loop = true };

    var preset = Preset{
        .name = try allocator.dupe(u8, "temp"),
        .channels = channels,
    };
    defer preset.deinit(allocator);

    try manager.save(preset);

    // Verify it exists
    var listed = try manager.listPresets();
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    for (listed) |name| allocator.free(name);
    allocator.free(listed);

    // Delete it
    try manager.delete("temp");

    // Verify it's gone
    listed = try manager.listPresets();
    defer allocator.free(listed);
    try std.testing.expectEqual(@as(usize, 0), listed.len);
}
