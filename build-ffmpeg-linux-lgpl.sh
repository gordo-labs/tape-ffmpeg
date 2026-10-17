#!/usr/bin/env bash
# Build the LGPL FFmpeg that Tape ships on Linux (Desktop AppImage/deb/rpm and the Docker image): audio only, fully
# static, no GPL, no non-free. Same configuration as scripts/ffmpeg/build-ffmpeg-macos-lgpl.sh (minus AudioToolbox).
#
#   bash scripts/ffmpeg/build-ffmpeg-linux-lgpl.sh arm64
#   bash scripts/ffmpeg/build-ffmpeg-linux-lgpl.sh x64      # on Apple Silicon: emulated amd64 container, slower
#
# Runs in a debian:bookworm container (Docker Desktop is enough; the host may be macOS or Linux). Output:
# ffmpeg/out/ffmpeg-8.1.3-linux-<arch>-lgpl.tar.xz (bin/ffmpeg, LICENSE texts, BUILDINFO.txt) and its SHA-256.
# The build smoke-tests the binary with the recipes the hub uses (HLS AAC/MP3, DASH FLAC, PCM waveform).
set -euo pipefail

FFMPEG_VERSION=8.1.3
LAME_VERSION=3.100
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ "${1:-}" != "--inside" ]]; then
  ARCH="${1:-}"
  case "$ARCH" in
    arm64) PLATFORM=linux/arm64 ;;
    x64) PLATFORM=linux/amd64 ;;
    *) echo "Usage: $0 arm64|x64" >&2; exit 2 ;;
  esac
  command -v docker >/dev/null || { echo "Docker is required" >&2; exit 1; }
  CACHE="${TAPE_FFMPEG_WORK:-$HOME/.cache/tape-ffmpeg-build}/linux-$ARCH"
  mkdir -p "$CACHE" "$ROOT/ffmpeg/out"
  exec docker run --rm --platform "$PLATFORM" \
    -v "$ROOT/scripts/ffmpeg:/scripts:ro" -v "$ROOT/ffmpeg/out:/out" -v "$CACHE:/work" \
    -e ARCH="$ARCH" -e FFMPEG_VERSION="$FFMPEG_VERSION" -e LAME_VERSION="$LAME_VERSION" \
    debian:bookworm bash /scripts/build-ffmpeg-linux-lgpl.sh --inside
fi

# ── Inside the container ────────────────────────────────────────────────────────────────────────────────────────
WORK=/work
OUT=/out
PREFIX="$WORK/prefix"
NAME="ffmpeg-$FFMPEG_VERSION-linux-$ARCH-lgpl"
JOBS="$(nproc)"
quiet() { local log="$1"; shift; "$@" >"$log" 2>&1 || { echo "Failed: $* (log: $log)" >&2; tail -30 "$log" >&2; exit 1; }; }

echo "== Toolchain"
quiet "$WORK/apt.log" bash -c 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends build-essential nasm pkg-config curl ca-certificates xz-utils'

cd "$WORK"
fetch() { [[ -f "$2" ]] || curl -fsSL "$1" -o "$2"; }
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz"
fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "lame-$LAME_VERSION.tar.gz"

if [[ -f "$PREFIX/lib/libmp3lame.a" ]]; then
  echo "== LAME $LAME_VERSION ($ARCH): already built"
else
  echo "== LAME $LAME_VERSION ($ARCH)"
  rm -rf "lame-$LAME_VERSION" && tar -xzf "lame-$LAME_VERSION.tar.gz"
  (
    cd "lame-$LAME_VERSION"
    # lame 3.100 exports a symbol that no longer exists; drop it so the static lib links.
    sed -i '/lame_init_old/d' include/libmp3lame.sym
    CFLAGS="-O2 -fPIC" ./configure --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend \
      --disable-decoder --build="$(gcc -dumpmachine)" >"$WORK/lame-configure.log" 2>&1
    quiet "$WORK/lame-build.log" make -j"$JOBS"
    quiet "$WORK/lame-install.log" make install
  )
fi

echo "== FFmpeg $FFMPEG_VERSION ($ARCH)"
rm -rf "ffmpeg-$FFMPEG_VERSION" && tar -xJf "ffmpeg-$FFMPEG_VERSION.tar.xz"
(
  cd "ffmpeg-$FFMPEG_VERSION"
  ./configure \
    --prefix="$WORK/ffmpeg-install" \
    --extra-cflags="-O2 -I$PREFIX/include" --extra-ldflags="-static -L$PREFIX/lib" --extra-libs="-lpthread -lm" \
    --pkg-config-flags=--static --enable-static --disable-shared \
    --disable-autodetect \
    --enable-libmp3lame \
    --disable-gpl --disable-nonfree \
    --disable-network --disable-doc --disable-ffplay --disable-ffprobe \
    --disable-avdevice \
    --disable-encoders --enable-encoder=aac,flac,libmp3lame,alac,pcm_s16le,pcm_s24le,pcm_f32le,mjpeg,png \
    > "$WORK/configure.log" 2>&1 || { echo "FFmpeg configure failed:" >&2; tail -15 "$WORK/configure.log" >&2; exit 1; }
  grep -q "License: LGPL" "$WORK/configure.log" || { echo "configure did not report an LGPL license" >&2; tail -20 "$WORK/configure.log" >&2; exit 1; }
  quiet "$WORK/ffmpeg-build.log" make -j"$JOBS"
  quiet "$WORK/ffmpeg-install.log" make install
)

STAGE="$WORK/$NAME"
rm -rf "$STAGE" && mkdir -p "$STAGE/bin"
cp "$WORK/ffmpeg-install/bin/ffmpeg" "$STAGE/bin/ffmpeg"
strip "$STAGE/bin/ffmpeg"
cp "ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$STAGE/LICENSE-FFmpeg-LGPL-2.1.txt"
cp "ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv3" "$STAGE/LICENSE-FFmpeg-LGPL-3.0.txt" 2>/dev/null || true
cp "lame-$LAME_VERSION/COPYING" "$STAGE/LICENSE-LAME.txt"
{
  echo "FFmpeg $FFMPEG_VERSION (https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz)"
  echo "LAME $LAME_VERSION (https://sourceforge.net/projects/lame/files/lame/$LAME_VERSION/)"
  echo "Target: Linux $ARCH, fully static (glibc, Debian bookworm toolchain), built by scripts/ffmpeg/build-ffmpeg-linux-lgpl.sh"
  "$STAGE/bin/ffmpeg" -hide_banner -version 2>/dev/null | sed -n '1,3p' || true
} > "$STAGE/BUILDINFO.txt"

FF="$STAGE/bin/ffmpeg"
if "$FF" -hide_banner -version 2>/dev/null | grep -Eq -- '--enable-(gpl|nonfree)'; then
  echo "Refusing: the build enables GPL or non-free code" >&2; exit 1
fi
file_type="$(od -An -c -N4 "$FF" | tr -d ' ')"
[[ "$file_type" == *ELF* ]] || { echo "Not an ELF binary" >&2; exit 1; }
if ldd "$FF" >/dev/null 2>&1; then echo "Refusing: ffmpeg is dynamically linked" >&2; ldd "$FF" >&2; exit 1; fi

echo "== Smoke ($ARCH)"
SMOKE="$(mktemp -d)"
(
  cd "$SMOKE"
  "$FF" -v error -f lavfi -i "sine=frequency=440:duration=6" -ac 2 -ar 44100 -c:a pcm_s16le src.wav 2>/dev/null \
    || "$FF" -v error -f s16le -ar 44100 -ac 2 -t 6 -i /dev/zero -c:a pcm_s16le src.wav
  "$FF" -v error -i src.wav -c:a flac src.flac
  mkdir -p dash hls mp3
  "$FF" -v error -threads 1 -i src.flac -vn -c:a flac -strict experimental -ar 44100 -ac 2 -f dash -seg_duration 2 \
    -use_template 1 -use_timeline 0 -hls_playlist 1 -init_seg_name init.mp4 -media_seg_name 'segment$Number$.m4s' dash/manifest.mpd
  "$FF" -v error -threads 1 -i src.flac -vn -c:a aac -b:a 256k -ar 44100 -ac 2 -f hls -hls_time 2 -hls_list_size 0 \
    -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 -hls_segment_filename hls/segment%d.m4s \
    -hls_playlist_type event -hls_flags independent_segments+temp_file -start_number 0 hls/playlist.m3u8
  "$FF" -v error -threads 1 -i src.flac -vn -c:a libmp3lame -b:a 320k -ar 44100 -ac 2 -f hls -hls_time 2 -hls_list_size 0 \
    -hls_segment_filename mp3/segment%d.ts -hls_playlist_type event mp3/playlist.m3u8
  "$FF" -v error -i src.flac -c:a alac src.m4a
  pcm_bytes="$("$FF" -v quiet -i src.flac -ac 1 -ar 22050 -f s16le - | wc -c)"
  [[ -f dash/init.mp4 && -f dash/media_0.m3u8 ]] || { echo "DASH FLAC failed" >&2; exit 1; }
  [[ "$(grep -c EXTINF hls/playlist.m3u8)" -ge 3 && "$(grep -c EXTINF mp3/playlist.m3u8)" -ge 3 ]] || { echo "HLS failed" >&2; exit 1; }
  [[ "$pcm_bytes" -gt 200000 ]] || { echo "PCM decode failed" >&2; exit 1; }
  echo "   DASH FLAC, HLS AAC fMP4, HLS MP3 320, ALAC, PCM waveform: OK"
)
rm -rf "$SMOKE"

tar -C "$WORK" -cJf "$OUT/$NAME.tar.xz" "$NAME"
echo "   size: $(du -h "$STAGE/bin/ffmpeg" | cut -f1) (binary), $(du -h "$OUT/$NAME.tar.xz" | cut -f1) (archive)"
sha256sum "$OUT/$NAME.tar.xz"
echo "✅ ffmpeg/out/$NAME.tar.xz"
