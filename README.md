# Tape FFmpeg builds

LGPL FFmpeg 8.1.3 binaries shipped with Tape Desktop and the Tape Docker image (no GPL, no non-free components).

- macOS arm64 / x64: audio only, built with `build-ffmpeg-macos-lgpl.sh` from https://ffmpeg.org/releases/ffmpeg-8.1.3.tar.xz and LAME 3.100.
- Linux x64 / arm64: audio only, fully static, built with `build-ffmpeg-linux-lgpl.sh` (debian:bookworm container) from the same sources.
- Windows: mirror of BtbN/FFmpeg-Builds `autobuild-2026-10-16-13-04` (lgpl variant); source and build scripts at https://github.com/BtbN/FFmpeg-Builds. (The BtbN Linux archives also remain here for builds pinned to them.)

FFmpeg is licensed under the LGPL (https://ffmpeg.org/legal.html); each archive includes the license texts and a BUILDINFO.txt with the configure line.
