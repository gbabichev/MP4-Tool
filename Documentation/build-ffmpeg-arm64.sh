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
echo "Building FFmpeg..."
echo "==================================="
if [ ! -d "ffmpeg" ]; then
    git clone --depth 1 https://git.ffmpeg.org/ffmpeg.git ffmpeg
fi
cd ffmpeg

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
