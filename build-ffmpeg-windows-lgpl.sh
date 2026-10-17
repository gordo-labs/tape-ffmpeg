#!/usr/bin/env bash
# Build Tape's Windows x64 FFmpeg from pinned upstream FFmpeg and LAME sources.
# Run from MSYS2 MINGW64 (MSYS2 x86_64 on Windows ARM64 works under Windows x64 emulation):
#   bash scripts/ffmpeg/build-ffmpeg-windows-lgpl.sh
# Output: ffmpeg/out/ffmpeg-8.1.3-win32-x64-lgpl-audio.zip
set -euo pipefail

FFMPEG_VERSION=8.1.3
LAME_VERSION=3.100
FFMPEG_SHA256=7138d28c96d9d3e3af4ee3d8cad72741f8ffb40da90c1112235dea3ecd3178a3
LAME_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
HOST=x86_64-w64-mingw32
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${TAPE_FFMPEG_WORK:-/c/dev/.cache/tape-ffmpeg-build/win32-x64}"
SRC="$WORK/src"
PREFIX="$WORK/prefix"
OUT="$ROOT/ffmpeg/out"
NAME="ffmpeg-$FFMPEG_VERSION-win32-x64-lgpl-audio"
JOBS="${TAPE_FFMPEG_JOBS:-$(nproc)}"

for tool in "$HOST-gcc" "$HOST-gcc-ar" ar ranlib nm strip nasm make pkgconf cmp sha256sum zip; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing build tool: $tool (use MSYS2 MINGW64)" >&2; exit 1; }
done

mkdir -p "$SRC" "$PREFIX" "$OUT"
cd "$SRC"
fetch() { [[ -f "$2" ]] || curl -fL "$1" -o "$2"; }
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz"
fetch "https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz" "lame-$LAME_VERSION.tar.gz"
echo "$FFMPEG_SHA256  ffmpeg-$FFMPEG_VERSION.tar.xz" | sha256sum -c -
echo "$LAME_SHA256  lame-$LAME_VERSION.tar.gz" | sha256sum -c -

quiet() {
  local log="$1"
  shift
  "$@" >"$log" 2>&1 || { echo "Failed: $* (log: $log)" >&2; tail -40 "$log" >&2; exit 1; }
}

rm -rf "lame-$LAME_VERSION"
tar -xzf "lame-$LAME_VERSION.tar.gz"
echo "== LAME $LAME_VERSION ($HOST)"
(
  cd "lame-$LAME_VERSION"
  # LAME 3.100 exports an obsolete symbol that breaks static linking with current binutils.
  sed -i '/lame_init_old/d' include/libmp3lame.sym
  CFLAGS="-O2" LDFLAGS="-static" ./configure --host="$HOST" \
    --prefix="$PREFIX" --enable-static --disable-shared --disable-frontend --disable-decoder \
    >"$WORK/lame-configure.log" 2>&1 || { tail -40 "$WORK/lame-configure.log" >&2; exit 1; }
  quiet "$WORK/lame-build.log" make -j"$JOBS"
  quiet "$WORK/lame-install.log" make install
)

rm -rf "ffmpeg-$FFMPEG_VERSION"
tar -xJf "ffmpeg-$FFMPEG_VERSION.tar.xz"
echo "== FFmpeg $FFMPEG_VERSION ($HOST)"
(
  cd "ffmpeg-$FFMPEG_VERSION"
  export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
  export PKG_CONFIG_LIBDIR="$PKG_CONFIG_PATH"
  CONFIGURE_FLAGS=(
    --prefix="$WORK/ffmpeg-install"
    --arch=x86_64 --target-os=mingw32 --cross-prefix="$HOST-" --enable-cross-compile
    --cc="$HOST-gcc" --ar=ar --ranlib=ranlib --nm=nm --strip=strip
    --x86asmexe=nasm --enable-x86asm
    --extra-cflags="-O2 -I$PREFIX/include"
    --extra-ldflags="-L$PREFIX/lib -static -static-libgcc"
    --pkg-config-flags=--static --enable-static --disable-shared
    --disable-gpl --disable-nonfree --disable-network --disable-doc --disable-ffplay --disable-ffprobe
    --disable-avdevice --disable-autodetect --enable-zlib --enable-libmp3lame --enable-version3
    --disable-encoders --enable-encoder=aac,flac,libmp3lame,alac,pcm_s16le,pcm_s24le,pcm_f32le,mjpeg,png
    # Keep only the audio decoders and containers Tape uses. M4A is MOV/MP4 with AAC or ALAC;
    # OGG libraries may contain Vorbis or Opus. HLS AAC and FLAC DASH are the app's current profiles.
    --disable-decoders --enable-decoder=aac,alac,flac,mp3,mp3float,opus,pcm_f32le,pcm_s16le,pcm_s24le,vorbis
    --disable-demuxers --enable-demuxer=flac,mp3,mov,mpegts,ogg,wav
    --disable-muxers --enable-muxer=adts,dash,flac,hls,image2,mov,mpegts,mp3,ogg,pcm_s16le,wav
    # The Hub streams analysis PCM from FFmpeg stdout; pipe is required for
    # waveforms and BPM/key analysis in addition to file-based HLS media.
    --disable-protocols --enable-protocol=file,pipe
    --disable-filters --enable-filter=aresample
  )
  printf '%s\n' "${CONFIGURE_FLAGS[@]}" > "$WORK/configure-flags.txt"
  ./configure "${CONFIGURE_FLAGS[@]}" >"$WORK/configure.log" 2>&1 || { tail -40 "$WORK/configure.log" >&2; exit 1; }
  grep -q 'License: LGPL' "$WORK/configure.log" || { echo 'configure did not report an LGPL license' >&2; tail -40 "$WORK/configure.log" >&2; exit 1; }
  quiet "$WORK/ffmpeg-build.log" make -j"$JOBS"
  quiet "$WORK/ffmpeg-install.log" make install
)

STAGE="$WORK/$NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin"
cp "$WORK/ffmpeg-install/bin/ffmpeg.exe" "$STAGE/bin/ffmpeg.exe"
strip "$STAGE/bin/ffmpeg.exe"
cp "$SRC/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv2.1" "$STAGE/LICENSE-FFmpeg-LGPL-2.1.txt"
cp "$SRC/ffmpeg-$FFMPEG_VERSION/COPYING.LGPLv3" "$STAGE/LICENSE-FFmpeg-LGPL-3.0.txt"
cp "$SRC/lame-$LAME_VERSION/COPYING" "$STAGE/LICENSE-LAME.txt"
{
  echo "FFmpeg $FFMPEG_VERSION source: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  echo "FFmpeg source SHA-256: $FFMPEG_SHA256"
  echo "LAME $LAME_VERSION source: https://downloads.sourceforge.net/project/lame/lame/$LAME_VERSION/lame-$LAME_VERSION.tar.gz"
  echo "LAME source SHA-256: $LAME_SHA256"
  echo "Target: Windows x64 (x86_64-w64-mingw32), static, LGPL"
  echo "Configure flags:"
  cat "$WORK/configure-flags.txt"
  echo ""
  "$STAGE/bin/ffmpeg.exe" -hide_banner -version 2>&1 | sed -n '1,3p'
} > "$STAGE/BUILDINFO.txt"

if "$STAGE/bin/ffmpeg.exe" -hide_banner -version 2>&1 | grep -Eq -- '--enable-(gpl|nonfree)'; then
  echo 'Refusing: the build enables GPL or non-free code' >&2
  exit 1
fi
for encoder in aac flac libmp3lame alac pcm_s16le pcm_s24le pcm_f32le mjpeg png; do
  "$STAGE/bin/ffmpeg.exe" -hide_banner -encoders 2>&1 | grep -Eq "^[[:space:]]*[A-Za-z.]{6}[[:space:]]+$encoder([[:space:]]|$)" || {
    echo "Required encoder missing: $encoder" >&2; exit 1;
  }
done
for decoder in aac alac flac mp3 mp3float opus pcm_f32le pcm_s16le pcm_s24le vorbis; do
  "$STAGE/bin/ffmpeg.exe" -hide_banner -decoders 2>&1 | grep -Eq "^[[:space:]]*[A-Za-z.]{6}[[:space:]]+$decoder([[:space:]]|$)" || {
    echo "Required decoder missing: $decoder" >&2; exit 1;
  }
done
"$STAGE/bin/ffmpeg.exe" -hide_banner -muxers 2>&1 | grep -Eq '^[[:space:]]+[D ]E[[:space:]]+s16le([[:space:]]|$)' || {
  echo 'Required muxer missing: s16le' >&2; exit 1;
}
"$STAGE/bin/ffmpeg.exe" -hide_banner -protocols 2>&1 | grep -Eq '^[[:space:]]+pipe$' || {
  echo 'Required protocol missing: pipe' >&2; exit 1;
}

rm -f "$OUT/$NAME.zip"
(
  cd "$WORK"
  zip -9 -qr "$OUT/$NAME.zip" "$NAME"
)
SIZE="$(wc -c < "$OUT/$NAME.zip" | tr -d ' ')"
(( SIZE <= 31457280 )) || { echo "Archive is over 30 MiB: $SIZE bytes" >&2; exit 1; }
sha256sum "$OUT/$NAME.zip"
echo "Archive bytes: $SIZE"
echo "✅ $OUT/$NAME.zip"
