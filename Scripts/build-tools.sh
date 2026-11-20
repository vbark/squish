#!/bin/zsh
# Builds the bundled optimizers from pinned source as universal (arm64 + x86_64) binaries in Vendor/bin.
# Everything is linked statically against nothing but macOS system libraries.
# Prerequisites: brew install rustup cmake nasm
# This script is also the "corresponding source" record for the GPL/LGPL tools we ship.
#   Scripts/build-tools.sh            build everything missing from Vendor/bin
#   Scripts/build-tools.sh ffmpeg     rebuild one tool
set -euo pipefail
cd "${0:A:h}/.."
[[ -d /Applications/Xcode.app ]] && export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

OXIPNG=v10.2.1     # MIT
PNGQUANT=3.0.3     # GPL-3.0-or-later
MOZJPEG=v4.1.5     # IJG / BSD-3-Clause / zlib
GIFSICLE=1.98      # GPL-2.0-only
LIBWEBP=v1.6.0     # BSD-3-Clause
RESVG=v0.50.0      # Apache-2.0 OR MIT
QPDF=v12.4.2       # Apache-2.0
FFMPEG=n9.0.2      # LGPL-2.1-or-later (built without --enable-gpl)

ROOT=$PWD
SRC=$ROOT/.build/tools-src
OUT=$ROOT/Vendor/bin
export MACOSX_DEPLOYMENT_TARGET=14.0
export PATH="$HOME/.cargo/bin:$(brew --prefix rustup 2>/dev/null || echo /nonexistent)/bin:$PATH"
JOBS=$(sysctl -n hw.ncpu)
# Keep Homebrew libraries out of the binaries we ship.
CMAKE_COMMON=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local" -DBUILD_SHARED_LIBS=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5)

for cmd in cargo rustup cmake nasm git lipo curl; do
  command -v $cmd >/dev/null || { echo "missing $cmd. Run: brew install rustup cmake nasm"; exit 1; }
done
# Homebrew's rustup is keg-only and starts with no toolchain.
rustup default >/dev/null 2>&1 || rustup default stable
rustup target add aarch64-apple-darwin x86_64-apple-darwin >/dev/null
mkdir -p "$SRC" "$OUT"

ONLY=${1:-}
want() { # tool-name output-binary...
  local name=$1; shift
  [[ -n "$ONLY" ]] && { [[ "$ONLY" == "$name" ]]; return; }
  for bin in "$@"; do [[ -x "$OUT/$bin" ]] || return 0; done
  echo "$name: already built"; return 1
}

fetch() { # repo tag dir
  [[ -d "$SRC/$3" ]] || git clone --quiet --depth 1 --branch "$2" --recurse-submodules --shallow-submodules "https://github.com/$1.git" "$SRC/$3"
}

cargo_universal() { # dir binary [cargo args...]
  local dir=$1 bin=$2; shift 2
  for t in aarch64-apple-darwin x86_64-apple-darwin; do
    (cd "$SRC/$dir" && cargo build --quiet --release --target "$t" "$@")
  done
  lipo -create -output "$OUT/$bin" "$SRC/$dir/target/aarch64-apple-darwin/release/$bin" "$SRC/$dir/target/x86_64-apple-darwin/release/$bin"
}

if want oxipng oxipng; then
  echo "oxipng $OXIPNG"
  fetch oxipng/oxipng $OXIPNG oxipng
  cargo_universal oxipng oxipng
fi

if want pngquant pngquant; then
  echo "pngquant $PNGQUANT"
  fetch kornelski/pngquant $PNGQUANT pngquant
  cargo_universal pngquant pngquant --features static,z-static
fi

if want resvg resvg; then
  echo "resvg $RESVG"
  fetch linebender/resvg $RESVG resvg
  cargo_universal resvg resvg -p resvg
fi

mozjpeg_build() {
  fetch mozilla/mozjpeg $MOZJPEG mozjpeg
  for arch in arm64 x86_64; do
    [[ -f "$SRC/mozjpeg/build-$arch/libjpeg.a" && -x "$SRC/mozjpeg/build-$arch/jpegtran-static" ]] && continue
    cmake -S "$SRC/mozjpeg" -B "$SRC/mozjpeg/build-$arch" "${CMAKE_COMMON[@]}" \
      -DCMAKE_OSX_ARCHITECTURES=$arch -DCMAKE_SYSTEM_PROCESSOR=$arch \
      -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DPNG_SUPPORTED=OFF -DWITH_TURBOJPEG=OFF >/dev/null
    cmake --build "$SRC/mozjpeg/build-$arch" --target jpeg-static cjpeg-static jpegtran-static -j $JOBS >/dev/null
  done
}

if want mozjpeg cjpeg jpegtran; then
  echo "mozjpeg $MOZJPEG"
  mozjpeg_build
  for tool in cjpeg jpegtran; do
    lipo -create -output "$OUT/$tool" "$SRC/mozjpeg/build-arm64/$tool-static" "$SRC/mozjpeg/build-x86_64/$tool-static"
  done
fi

if want gifsicle gifsicle; then
  echo "gifsicle $GIFSICLE"
  if [[ ! -d "$SRC/gifsicle-$GIFSICLE" ]]; then
    curl -sfL "https://www.lcdf.org/gifsicle/gifsicle-$GIFSICLE.tar.gz" | tar -xz -C "$SRC"
  fi
  for arch in arm64 x86_64; do
    host=$([[ $arch == arm64 ]] && echo aarch64-apple-darwin || echo x86_64-apple-darwin)
    rm -rf "$SRC/gifsicle-build-$arch" && mkdir -p "$SRC/gifsicle-build-$arch"
    (cd "$SRC/gifsicle-build-$arch" && "$SRC/gifsicle-$GIFSICLE/configure" --quiet --host=$host \
       CC="clang -arch $arch" --disable-gifview --disable-gifdiff >/dev/null && make -s -j $JOBS >/dev/null)
  done
  lipo -create -output "$OUT/gifsicle" "$SRC/gifsicle-build-arm64/src/gifsicle" "$SRC/gifsicle-build-x86_64/src/gifsicle"
fi

if want libwebp cwebp webpmux; then
  echo "libwebp $LIBWEBP"
  fetch webmproject/libwebp $LIBWEBP libwebp
  for arch in arm64 x86_64; do
    cmake -S "$SRC/libwebp" -B "$SRC/libwebp/build-$arch" "${CMAKE_COMMON[@]}" -DCMAKE_OSX_ARCHITECTURES=$arch \
      -DCMAKE_SYSTEM_PROCESSOR=$arch \
      -DWEBP_BUILD_CWEBP=ON -DWEBP_BUILD_WEBPMUX=ON -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
      -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_ANIM_UTILS=OFF \
      -DWEBP_BUILD_EXTRAS=OFF -DCMAKE_DISABLE_FIND_PACKAGE_PNG=ON -DCMAKE_DISABLE_FIND_PACKAGE_JPEG=ON \
      -DCMAKE_DISABLE_FIND_PACKAGE_TIFF=ON -DCMAKE_DISABLE_FIND_PACKAGE_GIF=ON >/dev/null
    cmake --build "$SRC/libwebp/build-$arch" --target cwebp webpmux -j $JOBS >/dev/null
  done
  for tool in cwebp webpmux; do
    lipo -create -output "$OUT/$tool" "$SRC/libwebp/build-arm64/$tool" "$SRC/libwebp/build-x86_64/$tool"
  done
fi

if want qpdf qpdf; then
  echo "qpdf $QPDF"
  mozjpeg_build # qpdf links libjpeg; reuse mozjpeg's
  fetch qpdf/qpdf $QPDF qpdf
  for arch in arm64 x86_64; do
    rm -rf "$SRC/qpdf/build-$arch"
    # PKG_CONFIG_LIBDIR hides Homebrew's libjpeg, which pkg-config would otherwise link dynamically.
    PKG_CONFIG_LIBDIR=/var/empty cmake -S "$SRC/qpdf" -B "$SRC/qpdf/build-$arch" "${CMAKE_COMMON[@]}" -DCMAKE_OSX_ARCHITECTURES=$arch \
      -DBUILD_STATIC_LIBS=ON -DREQUIRE_CRYPTO_NATIVE=ON -DUSE_IMPLICIT_CRYPTO=OFF -DBUILD_DOC=OFF \
      -DLIBJPEG_H_PATH="$SRC/mozjpeg;$SRC/mozjpeg/build-$arch" -DLIBJPEG_LIB_PATH="$SRC/mozjpeg/build-$arch/libjpeg.a" >/dev/null
    cmake --build "$SRC/qpdf/build-$arch" --target qpdf -j $JOBS >/dev/null
  done
  lipo -create -output "$OUT/qpdf" "$SRC/qpdf/build-arm64/qpdf/qpdf" "$SRC/qpdf/build-x86_64/qpdf/qpdf"
fi

if want ffmpeg ffmpeg; then
  echo "ffmpeg $FFMPEG (LGPL, VideoToolbox/AudioToolbox encoders only)"
  fetch FFmpeg/FFmpeg $FFMPEG ffmpeg
  for arch in arm64 x86_64; do
    build="$SRC/ffmpeg-build-$arch"
    rm -rf "$build" && mkdir -p "$build"
    cross=() && [[ $arch != $(uname -m) ]] && cross=(--enable-cross-compile --disable-x86asm)
    (cd "$build" && "$SRC/ffmpeg/configure" --arch=$arch --target-os=darwin "${cross[@]}" \
      --cc="clang -arch $arch" --extra-cflags="-mmacosx-version-min=14.0" --extra-ldflags="-arch $arch -mmacosx-version-min=14.0" \
      --disable-everything --disable-autodetect --disable-doc --disable-network --disable-debug \
      --disable-ffplay --disable-ffprobe --enable-videotoolbox --enable-audiotoolbox \
      --enable-encoder=h264_videotoolbox,hevc_videotoolbox,aac_at \
      --enable-decoder=h264,hevc,mpeg4,prores,mjpeg,aac,aac_at,alac,mp3,mp3float,pcm_s16le,pcm_s24le,pcm_f32le \
      --enable-demuxer=mov,mp3,aac,wav \
      --enable-muxer=mp4,mov,ipod,mp3 \
      --enable-parser=h264,hevc,aac,mpegaudio \
      --enable-bsf=aac_adtstoasc,h264_mp4toannexb \
      --enable-protocol=file --enable-filter=scale,format,aresample,aformat,null,anull >/dev/null && make -s -j $JOBS >/dev/null)
  done
  lipo -create -output "$OUT/ffmpeg" "$SRC/ffmpeg-build-arm64/ffmpeg" "$SRC/ffmpeg-build-x86_64/ffmpeg"
fi

# Fail loudly if anything picked up a non-system library.
for bin in "$OUT"/*; do
  if otool -L "$bin" | grep -E "^[[:space:]]" | grep -vqE "^[[:space:]]*(/usr/lib/|/System/Library/)"; then
    echo "error: $bin links a non-system library:"; otool -L "$bin"; exit 1
  fi
done
lipo -info "$OUT"/*
