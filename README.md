# atmora

A terminal user interface (TUI) app for mixing ambient audio sources without a browser.

Mix and layer various ambient sounds like cafe ambience, rain, ocean waves, and more—all from your terminal.

*Please note: I am using this project to teach myself zig. The code is probably bad, un-idiomatic, etc. all blame belongs to claude code. In the case that I accidentally did something right all praise is to be heaped upon myself personally.*

## Features

### Audio Mixing
- **Multi-channel audio mixing**: Up to 9 simultaneous audio tracks
- **Per-channel controls**: Independent volume (0-100%), mute, solo, loop, play/pause
- **Solo mode**: Isolate a single channel while muting others (only one channel can be soloed at a time)
- **Streaming playback**: Efficient streaming for large audio files

### File Management
- **Integrated file browser**: Navigate your filesystem directly in the TUI
- **Filter by format**: Automatically shows only supported audio files (MP3, WAV, FLAC)
- **Hidden file toggle**: Show/hide hidden files and directories

### Preset System
- **Save/load presets**: Store your favorite channel combinations as JSON files
- **Preset cycling**: Quickly browse through saved presets with a single key
- **Dirty state tracking**: Visual indicator shows when current state differs from loaded preset
- **Unsaved changes protection**: Confirmation prompts before loading a new preset or quitting with unsaved changes
- **Preset location**: `~/.config/atmora/presets/`

### User Experience
- **Keyboard-driven**: Everything accessible via keyboard shortcuts
- **Channel selection**: Number keys (1-9) or arrow keys for navigation
- **Temporary alpha layout**: It's not the prettiest but it's workable

### Audio Format Support
- **MP3** (.mp3) - Streaming decode via miniaudio
- **WAV** (.wav) - Uncompressed audio
- **FLAC** (.flac) - Lossless compression

### Cross-Platform
- **Linux**: ALSA, PulseAudio, PipeWire **Tested working (on one machine, omarchy btw)**
- **macOS**: CoreAudio - **Should work, untested**
- **WSL**: Audio passthrough to Windows host - **Should work, untested**

## Tech Stack

- **Language**: Zig 0.15.1
- **Audio Engine**: [zaudio](https://github.com/zig-gamedev/zig-gamedev) (miniaudio wrapper from zig-gamedev)
- **UI Layout**: [Clay](https://github.com/nicbarker/clay) via [clay-zig-bindings](https://github.com/johan0A/clay-zig-bindings)
- **Terminal Rendering**: Termbox2 backend

## Requirements

- Zig 0.15.1 or later
- Audio system: ALSA/PulseAudio/PipeWire (Linux), CoreAudio (macOS)

## Building

```bash
zig build
```

To run tests:
```bash
zig build test
```

## Usage

```bash
./zig-out/bin/atmora
```

Or build and run in one step:
```bash
zig build run
```

### Getting Started

1. **Launch atmora** - The file browser will appear on the right side
2. **Navigate to your audio files** - Use up and down arrow keys and Enter to browse
3. **Add audio files** - Press Enter on an audio file to add it as a channel
4. **Control playback**:
   - Select a channel with number keys (1-9)
   - Press Space to play/pause
   - Adjust volume with +/- keys
   - Toggle loop with L key
5. **Save your mix** - Press Ctrl+S to save as a preset
6. **Load presets** - Press P to cycle through saved presets

### Keyboard Controls

**Channels:**

- `1-9`: Select channel (press same number again to unselect)
- `Esc`: Unselect channel
- `Space`: Play/pause selected channel
- `+/-`: Adjust volume (10% increments)
- `M`: Toggle mute
- `S`: Solo channel
- `L`: Toggle loop
- `D` or `Del`: Delete channel

**File Browser:**

- `Up/Down`: Navigate files and directories
- `Enter`: Add audio file or enter directory
- `Backspace`: Go to parent directory
- `H`: Toggle hidden files

**Presets:**
- `P`: Cycle through saved presets
- `Ctrl+S`: Save current state as preset
- `X`: Delete current preset (with confirmation)

**General:**
- `Q` or `Ctrl+C`: Quit

**Modal Dialogs:**

- `Tab` or `Left/Right`: Switch between buttons
- `Enter`: Confirm selection
- `Esc` or `N`: Cancel
- `Y`: Quick confirm

## Presets

Presets store your channel configurations as JSON files in `~/.config/atmora/presets/`.

Each preset contains:
- File paths for all channels
- Volume settings per channel
- Loop state per channel

### Example Preset

```json
{
  "channels": [
    {
      "path": "/path/to/rain.mp3",
      "volume": 75,
      "loop": true
    },
    {
      "path": "/path/to/cafe.mp3",
      "volume": 50,
      "loop": true
    }
  ]
}
```

### Preset Workflow

- **Save**: Press `Ctrl+S` to save current state (auto-generated filename with timestamp)
- **Load**: Press `P` to cycle through available presets
- **Modified indicator**: Orange `[modified]` appears when you change a loaded preset
- **Delete**: Press `X` to delete the current preset (requires confirmation)
- **Rename**: Not currently supported in-app, should work if you rename the file

## Development Status

**Working features**:

- ✅ Audio engine with multi-channel mixing
- ✅ Channel controls (volume, mute, solo, loop)
- ✅ File browser with format filtering
- ✅ Preset save/load/delete system

**Planned features**:
- [ ] Theming system with multiple color schemes
- [ ] Timer/one-shot sound system (Pomodoro features etc)
- [ ] Pane-based UI architecture (flexible layout)
- [ ] Web source integration (YouTube, SoundCloud)
- [ ] Basic audio effects (EQ, reverb, spatial audio)
- [ ] Built-in default sound files (You'll have to find your own for now)

See `PLAN.md` for the complete roadmap.

## Contributing

Mainly looking for testers at this point, especially on platforms other than arch linux on amd64 (the only thing I've tested on). Please don't directly contribute UI code at this point (unless it's a simple bugfix) as the alpha UI is temporary

**Areas that need work**:

- Cross-platform testing (especially macOS and WSL)
