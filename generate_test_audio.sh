#!/bin/bash
# Generate test audio files for atmora unit tests
# Uses ffmpeg to create short audio files with simple tones

set -e

# Create test_assets directory
mkdir -p test_assets

echo "Generating test audio files..."

# Generate a 2-second 440Hz sine wave (A4 note) in MP3 format
ffmpeg -f lavfi -i "sine=frequency=440:duration=2" -acodec libmp3lame -y test_assets/test.mp3 2>/dev/null
echo "✓ Created test_assets/test.mp3"

# Generate a 2-second 523Hz sine wave (C5 note) in MP3 format
ffmpeg -f lavfi -i "sine=frequency=523:duration=2" -acodec libmp3lame -y test_assets/test1.mp3 2>/dev/null
echo "✓ Created test_assets/test1.mp3"

# Generate a 2-second 659Hz sine wave (E5 note) in MP3 format
ffmpeg -f lavfi -i "sine=frequency=659:duration=2" -acodec libmp3lame -y test_assets/test2.mp3 2>/dev/null
echo "✓ Created test_assets/test2.mp3"

# Generate WAV format for format testing
ffmpeg -f lavfi -i "sine=frequency=440:duration=2" -y test_assets/test.wav 2>/dev/null
echo "✓ Created test_assets/test.wav"

# Generate FLAC format for format testing
ffmpeg -f lavfi -i "sine=frequency=440:duration=2" -y test_assets/test.flac 2>/dev/null
echo "✓ Created test_assets/test.flac"

echo ""
echo "Test audio files generated successfully!"
echo "Files are located in: test_assets/"
echo ""
echo "To run tests with these files:"
echo "  zig build test"
