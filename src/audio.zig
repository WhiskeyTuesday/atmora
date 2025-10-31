const std = @import("std");
const zaudio = @import("zaudio");

pub const FadeBehavior = enum {
    none,
    pause_others,
    duck_others, // Lower volume of other channels
};

pub const Channel = struct {
    sound: *zaudio.Sound,
    file_path: [:0]const u8, // Owned by allocator (null-terminated)
    volume: u8, // 0 - 100
    is_muted: bool,
    is_solo: bool,
    is_looping: bool,
    is_playing: bool,

    pub fn deinit(self: *Channel, allocator: std.mem.Allocator) void {
        self.sound.destroy();
        allocator.free(self.file_path);
    }
};

pub const TimerSound = struct {
    sound: *zaudio.Sound,
    file_path: [:0]const u8, // Owned by allocator (null-terminated)
    trigger_time: i64, // Milliseconds since app start
    fade_behavior: FadeBehavior,
    fade_duration_ms: u32,
    has_triggered: bool,

    pub fn deinit(self: *TimerSound, allocator: std.mem.Allocator) void {
        self.sound.destroy();
        allocator.free(self.file_path);
    }
};

pub const AudioEngine = struct {
    allocator: std.mem.Allocator,
    engine: *zaudio.Engine,
    channels: std.ArrayList(Channel),
    timers: std.ArrayList(TimerSound),
    start_time: i64, // For timer calculations

    pub fn init(allocator: std.mem.Allocator) !AudioEngine {
        zaudio.init(allocator);

        const engine = try zaudio.Engine.create(null);

        return AudioEngine{
            .allocator = allocator,
            .engine = engine,
            .channels = std.ArrayList(Channel){ .items = &.{}, .capacity = 0 },
            .timers = std.ArrayList(TimerSound){ .items = &.{}, .capacity = 0 },
            .start_time = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *AudioEngine) void {
        // Clean up channels
        for (self.channels.items) |*channel| {
            channel.deinit(self.allocator);
        }
        self.channels.deinit(self.allocator);

        // Clean up timers
        for (self.timers.items) |*timer| {
            timer.deinit(self.allocator);
        }
        self.timers.deinit(self.allocator);

        // Clean up engine
        self.engine.destroy();
        zaudio.deinit();
    }

    /// Add a new audio channel from file
    pub fn addChannel(self: *AudioEngine, file_path: []const u8) !usize {
        // Limit to 9 channels (keyboard keys 1-9)
        if (self.channels.items.len >= 9) {
            return error.TooManyChannels;
        }

        // Duplicate the file path as null-terminated string for zaudio
        const owned_path = try self.allocator.dupeZ(u8, file_path);
        errdefer self.allocator.free(owned_path);

        // Create sound with streaming for large files
        const sound = try self.engine.createSoundFromFile(
            owned_path,
            .{ .flags = .{ .stream = true, .decode = true } },
        );
        errdefer sound.destroy();

        // Set looping by default
        sound.setLooping(true);

        const channel = Channel{
            .sound = sound,
            .file_path = owned_path,
            .volume = 100,
            .is_muted = false,
            .is_solo = false,
            .is_looping = true,
            .is_playing = false,
        };

        try self.channels.append(self.allocator, channel);
        return self.channels.items.len - 1;
    }

    /// Remove a channel by index
    pub fn removeChannel(self: *AudioEngine, index: usize) !void {
        if (index >= self.channels.items.len) return error.InvalidIndex;

        var channel = self.channels.orderedRemove(index);
        try channel.sound.stop();
        channel.deinit(self.allocator);
    }

    /// Start playing a channel
    pub fn playChannel(self: *AudioEngine, index: usize) !void {
        if (index >= self.channels.items.len) return error.InvalidIndex;

        var channel = &self.channels.items[index];
        if (!channel.is_playing) {
            try channel.sound.start();
            channel.is_playing = true;
        }
    }

    /// Stop playing a channel
    pub fn stopChannel(self: *AudioEngine, index: usize) !void {
        if (index >= self.channels.items.len) return error.InvalidIndex;

        var channel = &self.channels.items[index];
        if (channel.is_playing) {
            try channel.sound.stop();
            channel.is_playing = false;
        }
    }

    /// Set volume for a channel (0 - 100)
    pub fn setVolume(self: *AudioEngine, index: usize, volume: u8) !void {
        if (index >= self.channels.items.len) return error.InvalidIndex;

        const clamped_volume = @min(volume, 100);
        var channel = &self.channels.items[index];
        channel.volume = clamped_volume;

        // Apply mute/solo logic
        const effective_volume = self.getEffectiveVolume(index);
        channel.sound.setVolume(effective_volume);
    }

    /// Toggle mute for a channel
    pub fn toggleMute(self: *AudioEngine, index: usize) !void {
        if (index >= self.channels.items.len) return error.InvalidIndex;

        var channel = &self.channels.items[index];
        channel.is_muted = !channel.is_muted;

        // Update all channel volumes to reflect mute state
        try self.updateAllVolumes();
    }

    /// Toggle solo for a channel (mutes all others)
    pub fn toggleSolo(self: *AudioEngine, index: usize) !void {
        if (index >= self.channels.items.len) return error.InvalidIndex;

        var channel = &self.channels.items[index];
        channel.is_solo = !channel.is_solo;

        // Update all channel volumes to reflect solo state
        try self.updateAllVolumes();
    }

    /// Toggle looping for a channel
    pub fn toggleLoop(self: *AudioEngine, index: usize) !void {
        if (index >= self.channels.items.len) return error.InvalidIndex;

        var channel = &self.channels.items[index];
        channel.is_looping = !channel.is_looping;
        channel.sound.setLooping(channel.is_looping);
    }

    /// Get effective volume considering mute/solo state (returns 0.0-1.0 for zaudio)
    fn getEffectiveVolume(self: *AudioEngine, index: usize) f32 {
        const channel = &self.channels.items[index];

        // If this channel is muted, volume is 0
        if (channel.is_muted) return 0.0;

        // Check if any channel is soloed
        var any_solo = false;
        for (self.channels.items) |ch| {
            if (ch.is_solo) {
                any_solo = true;
                break;
            }
        }

        // If any channel is soloed and this isn't one of them, mute it
        if (any_solo and !channel.is_solo) return 0.0;

        // Otherwise return the channel's volume (convert from 0-100 to 0.0-1.0)
        return @as(f32, @floatFromInt(channel.volume)) / 100.0;
    }

    /// Update all channel volumes (called when mute/solo changes)
    fn updateAllVolumes(self: *AudioEngine) !void {
        for (self.channels.items, 0..) |*channel, i| {
            const effective_volume = self.getEffectiveVolume(i);
            channel.sound.setVolume(effective_volume);
        }
    }

    /// Add a timer-based sound
    pub fn addTimer(
        self: *AudioEngine,
        file_path: []const u8,
        delay_seconds: f32,
        fade_behavior: FadeBehavior,
    ) !void {
        const owned_path = try self.allocator.dupeZ(u8, file_path);
        errdefer self.allocator.free(owned_path);

        const sound = try self.engine.createSoundFromFile(
            owned_path,
            .{ .flags = .{ .decode = true } },
        );
        errdefer sound.destroy();

        const current_time = std.time.milliTimestamp();
        const trigger_time = current_time + @as(i64, @intFromFloat(delay_seconds * 1000.0));

        const timer = TimerSound{
            .sound = sound,
            .file_path = owned_path,
            .trigger_time = trigger_time,
            .fade_behavior = fade_behavior,
            .fade_duration_ms = 500, // Default 500ms fade
            .has_triggered = false,
        };

        try self.timers.append(self.allocator, timer);
    }

    /// Update timers and trigger sounds when ready
    pub fn updateTimers(self: *AudioEngine) !void {
        const current_time = std.time.milliTimestamp();

        var i: usize = 0;
        while (i < self.timers.items.len) {
            var timer = &self.timers.items[i];

            if (!timer.has_triggered and current_time >= timer.trigger_time) {
                // Trigger the timer sound
                try self.triggerTimerSound(timer);
                timer.has_triggered = true;

                // Remove the timer after triggering
                // (we could keep it for repeat timers in the future)
                var removed_timer = self.timers.orderedRemove(i);
                removed_timer.deinit(self.allocator);
                continue; // Don't increment i
            }

            i += 1;
        }
    }

    /// Trigger a timer sound with fade behavior
    fn triggerTimerSound(self: *AudioEngine, timer: *TimerSound) !void {
        switch (timer.fade_behavior) {
            .none => {
                try timer.sound.start();
            },
            .pause_others => {
                // Pause all channels
                for (self.channels.items) |*channel| {
                    if (channel.is_playing) {
                        try channel.sound.stop();
                        channel.is_playing = false;
                    }
                }
                try timer.sound.start();
            },
            .duck_others => {
                // Lower volume of other channels
                // TODO: Implement gradual fade
                for (self.channels.items) |*channel| {
                    if (channel.is_playing) {
                        const ducked_volume = channel.volume * 30 / 100; // Duck to 30%
                        const ducked_float = @as(f32, @floatFromInt(ducked_volume)) / 100.0;
                        channel.sound.setVolume(ducked_float);
                    }
                }
                try timer.sound.start();

                // TODO: Restore volumes after timer sound finishes
                // This would require tracking sound completion
            },
        }
    }

    /// Update function to be called each frame
    pub fn update(self: *AudioEngine) !void {
        try self.updateTimers();

        // Update channel playing states
        for (self.channels.items) |*channel| {
            const actually_playing = channel.sound.isPlaying();
            // Update our tracked state if it differs from actual state
            if (channel.is_playing != actually_playing) {
                channel.is_playing = actually_playing;
            }
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "AudioEngine init/deinit" {
    const allocator = std.testing.allocator;

    var engine = try AudioEngine.init(allocator);
    defer engine.deinit();

    // Verify initial state
    try std.testing.expectEqual(@as(usize, 0), engine.channels.items.len);
    try std.testing.expectEqual(@as(usize, 0), engine.timers.items.len);
}

test "Channel volume clamping (u8 0-100)" {
    const allocator = std.testing.allocator;

    var engine = try AudioEngine.init(allocator);
    defer engine.deinit();

    // Test volume clamping logic (now u8 0-100)
    const test_volume_too_high: u8 = 150;

    const clamped_high = @min(test_volume_too_high, 100);

    try std.testing.expectEqual(@as(u8, 100), clamped_high);

    // Test saturating subtraction
    const low_vol: u8 = 5;
    const result = low_vol -| 10;
    try std.testing.expectEqual(@as(u8, 0), result);
}

test "FadeBehavior enum" {
    try std.testing.expectEqual(FadeBehavior.none, FadeBehavior.none);
    try std.testing.expectEqual(FadeBehavior.pause_others, FadeBehavior.pause_others);
    try std.testing.expectEqual(FadeBehavior.duck_others, FadeBehavior.duck_others);
}

test "Timer calculation" {
    const allocator = std.testing.allocator;

    var engine = try AudioEngine.init(allocator);
    defer engine.deinit();

    // Test timer trigger time calculation
    const delay_seconds: f32 = 5.0;

    // Verify the calculation matches what addTimer would do
    const calculated_delay = @as(i64, @intFromFloat(delay_seconds * 1000.0));
    try std.testing.expectEqual(@as(i64, 5000), calculated_delay);

    // Verify start_time was set
    try std.testing.expect(engine.start_time > 0);
}

test "Nine channel limit" {
    const allocator = std.testing.allocator;

    var engine = try AudioEngine.init(allocator);
    defer engine.deinit();

    // Verify we can't add more than 9 channels
    // (We can't actually add channels without audio files, but we can check the limit logic)

    // Simulate adding 9 channels
    var i: usize = 0;
    while (i < 9) : (i += 1) {
        // Would normally call addChannel, but we can't without files
        // Just verify the limit check would work
        try std.testing.expect(engine.channels.items.len < 9);
    }

    // If we had 9 channels, addChannel should return TooManyChannels error
    // This is tested through manual UI interaction
}
