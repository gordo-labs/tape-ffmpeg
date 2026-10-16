#!/usr/bin/env bash
# Build the LGPL FFmpeg that Tape ships on macOS (audio only, static, no GPL, no non-free).
#
#   bash scripts/ffmpeg/build-ffmpeg-macos-lgpl.sh arm64
#   bash scripts/ffmpeg/build-ffmpeg-macos-lgpl.sh x64      # cross-compiles fine on Apple Silicon
#
# Output: ffmpeg/out/ffmpeg-8.1.3-macos-<arch>-lgpl.tar.xz (bin/ffmpeg, LICENSE texts, BUILDINFO.txt) and its SHA-256.
# Needs Xcode command line tools only (clang, make). Takes ~10-15 min per arch.
set -euo pipefail

ARCH="${1:-}"
case "$ARCH" in
  # LAME 3.100's config.sub predates "arm64": its host triple is aarch64.
  arm64) CLANG_ARCH=arm64; HOST_TRIPLE=aarch64-apple-darwin ;;
  x64) CLANG_ARCH=x86_64; HOST_TRIPLE=x86_64-apple-darwin ;;
  *) echo "Usage: $0 arm64|x64" >&2; exit 2 ;;
esac

FFMPEG_VERSION=8.1.3
LAME_VERSION=3.100
MIN_MACOS=11.0
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TAPE_FFMPEG_WORK:-$HOME/.cache/tape-ffmpeg-build}/$ARCH"
OUT="$ROOT/ffmpeg/out"
PREFIX="$WORK/prefix"
NAME="ffmpeg-$FFMPEG_VERSION-macos-$ARCH-lgpl"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p "$WORK" "$OUT" "$PREFIX"
cd "$WORK"

CFLAGS_COMMON="-arch $CLANG_ARCH -mmacosx-version-min=$MIN_MACOS -O2"
export MACOSX_DEPLOYMENT_TARGET=$MIN_MACOS

fetch() { [[ -f "$2" ]] || curl -fsSL "$1" -o "$2"; }
# Quiet build steps: output goes to a log; on failure show its tail.
quiet() { local log="$1"; shift; "$@" >"$log" 2>&1 || { echo "Failed: $* (log: $log)" >&2; tail -30 "$log" >&2; exit 1; }; }
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
  sed -i '' '/lame_init_old/d' include/libmp3lame.sym
  CFLAGS="$CFLAGS_COMMON" LDFLAGS="-arch $CLANG_ARCH" ./configure --host="$HOST_TRIPLE" \
    --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend --disable-decoder >"$WORK/lame-configure.log" 2>&1
  quiet "$WORK/lame-build.log" make -j"$JOBS"
  quiet "$WORK/lame-install.log" make install
)
fi

echo "== FFmpeg $FFMPEG_VERSION ($ARCH)"
rm -rf "ffmpeg-$FFMPEG_VERSION" && tar -xJf "ffmpeg-$FFMPEG_VERSION.tar.xz"
(
  cd "ffmpeg-$FFMPEG_VERSION"
  CROSS=()
  [[ "$(uname -m)" != "$CLANG_ARCH" ]] && CROSS=(--enable-cross-compile --target-os=darwin)
  # x86 hand-written assembly needs nasm (brew install nasm). Without it the build still works; audio barely notices.
  if [[ "$CLANG_ARCH" == "x86_64" ]] && ! command -v nasm >/dev/null 2>&1; then
    echo "   (nasm not found: building without x86 assembly; brew install nasm for the optimized build)"
    CROSS+=(--disable-x86asm)
  fi
  ./configure \
    --prefix="$WORK/ffmpeg-install" --arch="$CLANG_ARCH" --cc="clang -arch $CLANG_ARCH" ${CROSS[@]+"${CROSS[@]}"} \
    --extra-cflags="$CFLAGS_COMMON -I$PREFIX/include" --extra-ldflags="-arch $CLANG_ARCH -mmacosx-version-min=$MIN_MACOS -L$PREFIX/lib" \
    --pkg-config-flags=--static --enable-static --disable-shared \
    --disable-autodetect --enable-audiotoolbox \
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
strip -x "$STAGE/bin/ffmpeg"
cp "ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$STAGE/LICENSE-FFmpeg-LGPL-2.1.txt"
cp "ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv3" "$STAGE/LICENSE-FFmpeg-LGPL-3.0.txt" 2>/dev/null || true
cp "lame-$LAME_VERSION/COPYING" "$STAGE/LICENSE-LAME.txt"
{
  echo "FFmpeg $FFMPEG_VERSION (https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz)"
  echo "LAME $LAME_VERSION (https://sourceforge.net/projects/lame/files/lame/$LAME_VERSION/)"
  echo "Target: macOS $MIN_MACOS+ $CLANG_ARCH, static, built by scripts/ffmpeg/build-ffmpeg-macos-lgpl.sh"
  "$STAGE/bin/ffmpeg" -hide_banner -version 2>/dev/null | sed -n '1,3p' || true
} > "$STAGE/BUILDINFO.txt"

if "$STAGE/bin/ffmpeg" -hide_banner -version 2>/dev/null | grep -Eq -- '--enable-(gpl|nonfree)'; then
  echo "Refusing: the build enables GPL or non-free code" >&2; exit 1
fi

tar -C "$WORK" -cJf "$OUT/$NAME.tar.xz" "$NAME"
shasum -a 256 "$OUT/$NAME.tar.xz"
echo "✅ $OUT/$NAME.tar.xz"
