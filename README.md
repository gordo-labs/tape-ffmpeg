# Tape FFmpeg builds

LGPL FFmpeg 8.1.3 binaries shipped with Tape Desktop and the Tape Docker image (no GPL, no non-free components).

- Windows x64 / ARM64: audio-only static builds from FFmpeg 8.1.3 and LAME 3.100, built with `build-ffmpeg-windows-lgpl.sh` and `build-ffmpeg-windows-arm64-lgpl.sh`. Archives are in [release ffmpeg-8.1.3-lgpl-2](https://github.com/gordo-labs/tape-ffmpeg/releases/tag/ffmpeg-8.1.3-lgpl-2).
- macOS x64 / arm64: audio-only builds from FFmpeg 8.1.3 and LAME 3.100; see [release ffmpeg-8.1.3-lgpl-1](https://github.com/gordo-labs/tape-ffmpeg/releases/tag/ffmpeg-8.1.3-lgpl-1) and `build-ffmpeg-macos-lgpl.sh`.
- Linux x64 / arm64: existing pinned LGPL archives remain in [release ffmpeg-8.1.3-lgpl-1](https://github.com/gordo-labs/tape-ffmpeg/releases/tag/ffmpeg-8.1.3-lgpl-1). Their build script is `build-ffmpeg-linux-lgpl.sh`.

The Windows scripts pin the SHA-256 of both source archives and include the LGPL-only configure flags. Each binary archive includes the LGPL/LAME license texts and `BUILDINFO.txt`.

FFmpeg is licensed under the LGPL: https://ffmpeg.org/legal.html.
