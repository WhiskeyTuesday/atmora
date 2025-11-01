# Demo Audio Setup

This directory is for placing audio files to manually test atmora's multi-channel mixing features.

**Note**: This directory is for **manual testing** of the application. For unit test audio files, see `test_assets/` which are auto-generated.

## Quick Setup

1. Find or download ambient audio files (rain, cafe, ocean, etc.)
2. Place them in this directory (any supported format)
3. Run atmora: `zig build run`
4. Use the file browser on the right to navigate to `demo_audio/`
5. Press **Enter** on audio files to add them as channels
6. Control playback:
   - Select channels with **1-9** keys
   - **Space**: Play/pause selected channel
   - **+/-**: Adjust volume
   - **L**: Toggle loop
   - **M**: Mute
   - **S**: Solo
7. **Ctrl+S** to save your mix as a preset
8. **P** to cycle through saved presets

## Supported Formats

atmora uses miniaudio which has built-in support for 3 formats:
- **MP3** (.mp3) - Most common format
- **WAV** (.wav) - Uncompressed audio
- **FLAC** (.flac) - Lossless compression

**Not supported** (would require external decoder libraries):
- OGG/Vorbis (.ogg) - Requires stb_vorbis
- AAC (.aac) - Requires external decoder
- Opus (.opus) - Requires external decoder


## Finding Test Audio

### Free Ambient Sounds

You can find free ambient audio at:
- [Freesound.org](https://freesound.org/) (CC-licensed sounds)
- [BBC Sound Effects](https://sound-effects.bbcrewind.co.uk/) (Free for personal use)
- [YouTube Audio Library](https://studio.youtube.com/channel/UCpPQv-FQTnGg93s6-rDNYBg/music) (Royalty-free)

[Archive.org rain noise](https://archive.org/details/free-and-excellent-rain-sound-effect-gentle-and-relaxing-effect/Free+and+Excellent+Rain+Sound+Effect+-+Gentle+And+Relaxing+Effect!.mp4). Needs to be converted to audio, use ffmpeg -i input_video.mp4 output_audio.mp3
[Archive.org white pink and brownian noise](https://archive.org/details/TenMinutesOfWhiteNoisePinkNoiseAndBrownianNoise/BrownianNoise.flac)

### Quick Test with System Sounds

On Linux, you can use existing system sounds:
```bash
# Copy a system sound as test audio
cp /usr/share/sounds/freedesktop/stereo/bell.oga demo_audio/ambient.mp3
```

### Generate Test Tone (with ffmpeg)

```bash
# Generate a 10-second 440Hz sine wave
ffmpeg -f lavfi -i "sine=frequency=440:duration=10" demo_audio/test.mp3
```

## Converting Between Formats (with ffmpeg)

If you have one audio file, you can convert it to all supported formats:

```bash
# Starting from any format (example: input.mp3)
SOURCE="path/to/your/audio.mp3"

# Convert to supported formats
ffmpeg -y -i "$SOURCE" demo_audio/test.mp3
ffmpeg -y -i "$SOURCE" demo_audio/test.wav
ffmpeg -y -i "$SOURCE" demo_audio/test.flac
```

Or as a one-liner:
```bash
SOURCE="path/to/your/audio.mp3"
for ext in mp3 wav flac; do ffmpeg -y -i "$SOURCE" "demo_audio/test.$ext"; done
```

## Manual Testing Checklist

### Basic Channel Operations
- [ ] Add multiple audio files as channels via file browser
- [ ] Select channel with **1-9** keys
- [ ] Press **Space** to play/pause selected channel
- [ ] Adjust volume with **+/-** keys
- [ ] Toggle loop with **L** key (audio repeats when playing)
- [ ] Mute channel with **M** key (volume goes to 0)
- [ ] Solo channel with **S** key (mutes all other channels)
- [ ] Delete channel with **D** or **Del** key
- [ ] Verify channel status updates (PLAYING/STOPPED)

### Preset System
- [ ] Create a mix with multiple channels and volumes
- [ ] Save preset with **Ctrl+S** (auto-generated timestamp name)
- [ ] Modify the mix (change volume, add/remove channels)
- [ ] Orange **[modified]** indicator appears when changed
- [ ] Press **P** to cycle through saved presets
- [ ] Confirmation dialog appears when loading with unsaved changes
- [ ] Delete preset with **X** key

### Format Support
- [ ] MP3 files load and play correctly
- [ ] WAV files load and play correctly
- [ ] FLAC files load and play correctly
- [ ] Multiple formats can play simultaneously

## Troubleshooting

**File won't load/play**
- Verify the file format is supported (MP3, WAV, or FLAC only)
- Check that the file isn't corrupted
- Try a different format (WAV is most reliable)
- Check terminal output for error messages

**Audio file loads but no sound**
- Check system volume
- Verify audio output device is working
- Check if the channel is muted (M key toggles)
- Check if another channel is soloed (S key toggles)
- Verify PulseAudio/PipeWire is running (Linux)

**App performance issues**
- Limit simultaneous channels (9 maximum by design)
- Large files use streaming, but many large files may impact performance
- Check CPU usage with `top` or `htop`
