#!/bin/bash

# FFmpeg ARM64 Static Build Script for macOS
# Builds FFmpeg with x264 (H.264) and x265 (H.265) support

set -e

# Configuration
BUILD_DIR="$HOME/ffmpeg-build"
PREFIX="$BUILD_DIR/install"
WORKSPACE="$BUILD_DIR/workspace"
ARCH="arm64"
MACOS_MIN_VERSION="11.0"

# Compiler flags for ARM64
export CFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN_VERSION -O3"
export CXXFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN_VERSION -O3"
export LDFLAGS="-arch $ARCH -mmacosx-version-min=$MACOS_MIN_VERSION"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# Create directory structure
echo "Creating build directories..."
mkdir -p "$WORKSPACE" "$PREFIX"

cd "$WORKSPACE"

# Build NASM (assembler needed for x264/x265)
echo "==================================="
echo "Building NASM..."
echo "==================================="
if [ ! -f "$PREFIX/bin/nasm" ]; then
    curl -L -O https://www.nasm.us/pub/nasm/releasebuilds/2.16.01/nasm-2.16.01.tar.bz2
    tar xjf nasm-2.16.01.tar.bz2
    cd nasm-2.16.01
    ./configure --prefix="$PREFIX"
    make -j$(sysctl -n hw.ncpu)
    make install
    cd ..
fi

export PATH="$PREFIX/bin:$PATH"

# Build x264
echo "==================================="
echo "Building x264 (H.264 encoder)..."
echo "==================================="
if [ ! -f "$PREFIX/lib/libx264.a" ]; then
    if [ ! -d "x264" ]; then
        git clone --depth 1 https://code.videolan.org/videolan/x264.git
    fi
    cd x264
    ./configure \
        --prefix="$PREFIX" \
        --enable-static \
        --disable-shared \
        --disable-cli \
        --enable-pic \
        --extra-cflags="$CFLAGS"
    make -j$(sysctl -n hw.ncpu)
    make install
    cd ..
fi

# Build x265
echo "==================================="
echo "Building x265 (H.265 encoder)..."
echo "==================================="
if [ ! -f "$PREFIX/lib/libx265.a" ]; then
    if [ ! -d "x265" ]; then
        git clone --depth 1 https://bitbucket.org/multicoreware/x265_git.git x265
    fi
    cd x265/build/linux
    cmake -G "Unix Makefiles" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN_VERSION" \
        -DENABLE_SHARED=OFF \
        -DENABLE_CLI=OFF \
        -DCMAKE_C_FLAGS="$CFLAGS" \
        -DCMAKE_CXX_FLAGS="$CXXFLAGS" \
        ../../source
    make -j$(sysctl -n hw.ncpu)
    make install
    cd ../../..
fi

# Build FFmpeg
echo "==================================="
echo "Building FFmpeg (8.0)..."
echo "==================================="

FFMPEG_REMOTE="https://git.ffmpeg.org/ffmpeg.git"
FFMPEG_DIR="ffmpeg"
FFMPEG_TAG="${FFMPEG_TAG:-n8.0}"                  # expected FFmpeg tag name
FFMPEG_BRANCH="${FFMPEG_BRANCH:-release/8.0}"     # fallback branch name
FFMPEG_OID="${FFMPEG_OID:-a4044e04486d1136022498891088a90baf5b2775}" # your link's object id

if [ ! -d "$FFMPEG_DIR/.git" ]; then
  # Shallow clone without checking out HEAD history
  git clone --no-checkout --filter=blob:none "$FFMPEG_REMOTE" "$FFMPEG_DIR"
fi

cd "$FFMPEG_DIR"

# Ensure we have the remote set and up to date
git remote set-url origin "$FFMPEG_REMOTE" >/dev/null 2>&1 || true

# Try tag first (best for a validated release)
if git fetch --depth 1 origin "tag" "$FFMPEG_TAG"; then
  git -c advice.detachedHead=false checkout --detach "tags/$FFMPEG_TAG"
else
  echo "Tag '$FFMPEG_TAG' not found, trying branch '$FFMPEG_BRANCH'..."
  if git fetch --depth 1 origin "$FFMPEG_BRANCH"; then
    git -c advice.detachedHead=false checkout --detach FETCH_HEAD
  else
    echo "Branch '$FFMPEG_BRANCH' not found, falling back to exact object id..."
    git fetch --depth 1 origin "$FFMPEG_OID"
    git -c advice.detachedHead=false checkout --detach "$FFMPEG_OID"
  fi
fi

# Optional: make a local branch name for clarity (still pinned to this commit)
git branch -f "ffmpeg-8.0" >/dev/null 2>&1 || true

echo "Checked out commit:"
git show -s --format="  %H  %d%n  %s%n  (describe: %D)"
git describe --tags --always 2>/dev/null || true

./configure \
    --prefix="$PREFIX" \
    --arch="$ARCH" \
    --cc="clang" \
    --cxx="clang++" \
    --extra-cflags="$CFLAGS -I$PREFIX/include" \
    --extra-ldflags="$LDFLAGS -L$PREFIX/lib" \
    --pkg-config-flags="--static" \
    --enable-gpl \
    --enable-version3 \
    --enable-libx264 \
    --enable-libx265 \
    --enable-static \
    --disable-shared \
    --disable-debug \
    --disable-doc \
    --disable-htmlpages \
    --disable-manpages \
    --disable-podpages \
    --disable-txtpages \
    --enable-videotoolbox \
    --enable-audiotoolbox

make -j$(sysctl -n hw.ncpu)
make install

echo "==================================="
echo "Build complete!"
echo "==================================="
echo "FFmpeg binary location: $PREFIX/bin/ffmpeg"
echo ""
echo "Verifying binary:"
otool -L "$PREFIX/bin/ffmpeg"
echo ""
echo "Testing codecs:"
"$PREFIX/bin/ffmpeg" -codecs | grep -E "h264|h265|hevc"
