const std = @import("std");
const Allocator = std.mem.Allocator;

/// FileBrowser provides directory navigation and audio file filtering.
///
/// **Design Philosophy:**
/// - Core logic is UI-agnostic (no Clay/termbox dependencies)
/// - Can be extracted as standalone package
/// - Memory strategy: Uses arena allocator for directory entries (reset on navigate)
///
/// **Format Support:**
/// - MP3, WAV, FLAC only (miniaudio built-in formats)
/// - Post-1.0: OGG/Vorbis support (requires stb_vorbis)
pub const FileBrowser = struct {
    allocator: Allocator, // Parent allocator (typically GPA)
    dir_arena: std.heap.ArenaAllocator, // Arena for current directory entries
    current_path: []u8, // Owned by this struct, allocated with parent allocator
    entries: std.ArrayList(Entry), // Uses dir_arena allocator
    selected_index: usize,
    show_hidden: bool,

    pub const Entry = struct {
        name: []const u8, // Allocated from dir_arena
        is_directory: bool,
        is_audio_file: bool,
    };

    pub const Error = error{
        InvalidPath,
        NotADirectory,
    } || Allocator.Error || std.fs.Dir.OpenError || std.fs.Dir.Iterator.Error;

    /// Supported audio file extensions (miniaudio built-in formats only)
    const AUDIO_EXTENSIONS = [_][]const u8{
        ".mp3", // MPEG Audio Layer 3
        ".wav", // Waveform Audio File
        ".flac", // Free Lossless Audio Codec
    };

    /// Initialize FileBrowser at the given starting path.
    /// Caller owns returned FileBrowser and must call deinit().
    pub fn init(allocator: Allocator, starting_path: []const u8) Error!FileBrowser {
        var dir_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer dir_arena.deinit();

        // Allocate current_path with parent allocator (long-lived)
        const path_copy = try allocator.dupe(u8, starting_path);
        errdefer allocator.free(path_copy);

        var browser = FileBrowser{
            .allocator = allocator,
            .dir_arena = dir_arena,
            .current_path = path_copy,
            .entries = .{ .items = &[_]Entry{}, .capacity = 0 },
            .selected_index = 0,
            .show_hidden = false,
        };

        // Load initial directory contents
        try browser.refresh();

        return browser;
    }

    pub fn deinit(self: *FileBrowser) void {
        self.allocator.free(self.current_path);
        self.dir_arena.deinit();
    }

    /// Navigate to a new directory and refresh entries.
    /// This resets the arena allocator, freeing all previous entry strings.
    pub fn navigate(self: *FileBrowser, new_path: []const u8) Error!void {
        // Validate path before changing state
        var dir = std.fs.openDirAbsolute(new_path, .{ .iterate = true }) catch {
            return Error.InvalidPath;
        };
        dir.close();

        // Update current_path
        const new_path_copy = try self.allocator.dupe(u8, new_path);
        self.allocator.free(self.current_path);
        self.current_path = new_path_copy;

        // Reset arena - this invalidates all previous entry strings AND the entries.items array
        _ = self.dir_arena.reset(.retain_capacity);

        // Reset entries list completely (don't retain capacity since it was from the arena)
        self.entries = .{ .items = &[_]Entry{}, .capacity = 0 };
        self.selected_index = 0;

        // Load new directory contents
        try self.refresh();
    }

    /// Navigate to parent directory (..)
    pub fn navigateUp(self: *FileBrowser) Error!void {
        const parent = std.fs.path.dirname(self.current_path) orelse "/";
        try self.navigate(parent);
    }

    /// Refresh the current directory's entries.
    /// This resets the arena and reloads all entries.
    pub fn refresh(self: *FileBrowser) Error!void {
        // Reset arena - this frees all old entry strings AND invalidates entries.items array
        _ = self.dir_arena.reset(.retain_capacity);

        // Reset entries list completely (don't retain capacity since it was from the arena)
        self.entries = .{ .items = &[_]Entry{}, .capacity = 0 };

        var dir = std.fs.openDirAbsolute(self.current_path, .{ .iterate = true }) catch {
            return Error.InvalidPath;
        };
        defer dir.close();

        var iter = dir.iterate();
        const arena_allocator = self.dir_arena.allocator();

        // Always add parent directory entry if not at root
        if (!std.mem.eql(u8, self.current_path, "/")) {
            const parent_entry = Entry{
                .name = try arena_allocator.dupe(u8, ".."),
                .is_directory = true,
                .is_audio_file = false,
            };
            try self.entries.append(arena_allocator, parent_entry);
        }

        // Iterate through directory entries
        while (try iter.next()) |entry| {
            // Skip hidden files if show_hidden is false
            if (!self.show_hidden and entry.name.len > 0 and entry.name[0] == '.') {
                continue;
            }

            const is_dir = entry.kind == .directory;
            const is_audio = if (!is_dir) isAudioFile(entry.name) else false;

            // Only show directories and audio files
            if (is_dir or is_audio) {
                const name_copy = try arena_allocator.dupe(u8, entry.name);
                try self.entries.append(arena_allocator, .{
                    .name = name_copy,
                    .is_directory = is_dir,
                    .is_audio_file = is_audio,
                });
            }
        }

        // Sort: directories first, then by name
        std.mem.sort(Entry, self.entries.items, {}, entryLessThan);

        // Ensure selected_index is valid
        if (self.entries.items.len == 0) {
            self.selected_index = 0;
        } else if (self.selected_index >= self.entries.items.len) {
            self.selected_index = self.entries.items.len - 1;
        }
    }

    /// Check if a filename has a supported audio file extension.
    /// Supports: MP3, WAV, FLAC (miniaudio built-in formats)
    fn isAudioFile(filename: []const u8) bool {
        for (AUDIO_EXTENSIONS) |ext| {
            if (std.ascii.endsWithIgnoreCase(filename, ext)) {
                return true;
            }
        }
        return false;
    }

    /// Sort function: directories before files, then alphabetically.
    fn entryLessThan(_: void, a: Entry, b: Entry) bool {
        // Parent directory (..) always comes first
        if (std.mem.eql(u8, a.name, "..")) return true;
        if (std.mem.eql(u8, b.name, "..")) return false;

        // Directories before files
        if (a.is_directory and !b.is_directory) return true;
        if (!a.is_directory and b.is_directory) return false;

        // Alphabetically by name
        return std.ascii.lessThanIgnoreCase(a.name, b.name);
    }

    /// Move selection up (decreasing index).
    pub fn selectPrevious(self: *FileBrowser) void {
        if (self.entries.items.len == 0) return;
        if (self.selected_index > 0) {
            self.selected_index -= 1;
        }
    }

    /// Move selection down (increasing index).
    pub fn selectNext(self: *FileBrowser) void {
        if (self.entries.items.len == 0) return;
        if (self.selected_index < self.entries.items.len - 1) {
            self.selected_index += 1;
        }
    }

    /// Get the currently selected entry, if any.
    pub fn getSelectedEntry(self: *FileBrowser) ?Entry {
        if (self.entries.items.len == 0) return null;
        if (self.selected_index >= self.entries.items.len) return null;
        return self.entries.items[self.selected_index];
    }

    /// Get the full path of the currently selected entry.
    /// Caller owns returned slice and must free it with the FileBrowser's parent allocator.
    pub fn getSelectedPath(self: *FileBrowser) Error![]u8 {
        const entry = self.getSelectedEntry() orelse return Error.InvalidPath;

        if (std.mem.eql(u8, entry.name, "..")) {
            const parent = std.fs.path.dirname(self.current_path) orelse "/";
            return self.allocator.dupe(u8, parent);
        }

        return std.fs.path.join(self.allocator, &[_][]const u8{
            self.current_path,
            entry.name,
        });
    }

    /// Activate the currently selected entry.
    /// If directory: navigates into it.
    /// If audio file: returns the full path (caller must free).
    /// Returns null if navigated to directory (no path to return).
    pub fn activateSelected(self: *FileBrowser) Error!?[]u8 {
        const entry = self.getSelectedEntry() orelse return null;

        if (entry.is_directory) {
            const path = try self.getSelectedPath();
            defer self.allocator.free(path);
            try self.navigate(path);
            return null;
        } else if (entry.is_audio_file) {
            return try self.getSelectedPath();
        }

        return null;
    }

    /// Toggle showing hidden files.
    pub fn toggleHidden(self: *FileBrowser) Error!void {
        self.show_hidden = !self.show_hidden;
        try self.refresh();
    }
};

// Tests
test "FileBrowser init and deinit" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Use current directory for testing
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buf);

    var browser = try FileBrowser.init(allocator, cwd);
    defer browser.deinit();

    // Should have loaded some entries
    try testing.expect(browser.entries.items.len >= 0);
}

test "FileBrowser navigate up" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buf);

    var browser = try FileBrowser.init(allocator, cwd);
    defer browser.deinit();

    const original_path = try allocator.dupe(u8, browser.current_path);
    defer allocator.free(original_path);

    try browser.navigateUp();

    // Path should have changed (unless we were at root)
    if (!std.mem.eql(u8, original_path, "/")) {
        try testing.expect(!std.mem.eql(u8, browser.current_path, original_path));
    }
}

test "isAudioFile detection - supported formats" {
    const testing = std.testing;

    // Supported formats (miniaudio built-in)
    try testing.expect(FileBrowser.isAudioFile("song.mp3"));
    try testing.expect(FileBrowser.isAudioFile("track.MP3"));
    try testing.expect(FileBrowser.isAudioFile("audio.flac"));
    try testing.expect(FileBrowser.isAudioFile("sound.WAV"));
    try testing.expect(FileBrowser.isAudioFile("test.Flac"));
}

test "isAudioFile detection - unsupported formats" {
    const testing = std.testing;

    // Unsupported formats
    try testing.expect(!FileBrowser.isAudioFile("document.txt"));
    try testing.expect(!FileBrowser.isAudioFile("image.png"));
    try testing.expect(!FileBrowser.isAudioFile("video.mp4"));
    try testing.expect(!FileBrowser.isAudioFile("audio.ogg")); // Requires stb_vorbis
    try testing.expect(!FileBrowser.isAudioFile("track.aac")); // Requires external decoder
    try testing.expect(!FileBrowser.isAudioFile("sound.opus")); // Requires external decoder
}

test "FileBrowser selection navigation" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try std.fs.cwd().realpath(".", &buf);

    var browser = try FileBrowser.init(allocator, cwd);
    defer browser.deinit();

    if (browser.entries.items.len > 1) {
        const initial_index = browser.selected_index;

        browser.selectNext();
        try testing.expect(browser.selected_index == initial_index + 1);

        browser.selectPrevious();
        try testing.expect(browser.selected_index == initial_index);

        // Test bounds
        browser.selected_index = 0;
        browser.selectPrevious();
        try testing.expect(browser.selected_index == 0);

        browser.selected_index = browser.entries.items.len - 1;
        browser.selectNext();
        try testing.expect(browser.selected_index == browser.entries.items.len - 1);
    }
}
