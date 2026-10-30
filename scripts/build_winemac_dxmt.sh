#!/usr/bin/env bash
set -euo pipefail

# Builds Wine's macOS driver (winemac.so) with DXMT support, matching the Gcenx
# Wine Staging build Moonshine installs. Only the driver is rebuilt.
#
# Changes (patches/wine/winemac-dxmt.patch):
#   - Exports a macdrv_functions table, which DXMT looks up with dlsym, translating
#     window data to the pre-Wine 11 layout DXMT expects
#   - Attaches a client view for DXMT windows, which Wine 11 only does for GL/Vulkan
#   - Accepts OpenGL 3.2+ context requests without the forward-compatible flag
#
# Usage:
#   ./scripts/build_winemac_dxmt.sh
#
# Output: ~/Library/Caches/Moonshine/dxmt-driver/winemac.so
# Install it with ./scripts/install_dxmt.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
source "$SCRIPT_DIR/lib/common.sh"

WINE_VERSION="11.18"
WINE_URL="https://dl.winehq.org/wine/source/11.x/wine-$WINE_VERSION.tar.xz"
WINE_SHA256="c6282f6d4daecf11f3ab9f9a2b6c598f67be7e28c363ba2cae8a3c44b611e7a4"
STAGING_URL="https://github.com/wine-staging/wine-staging/archive/refs/tags/v$WINE_VERSION.tar.gz"
STAGING_SHA256="be9ab2471ce3ef729484c9d7e2752790a9145e1bb0c0e680f01268d15e5488c5"
BISON_VERSION="3.8.2"
BISON_URL="https://ftp.gnu.org/gnu/bison/bison-$BISON_VERSION.tar.xz"
BISON_SHA256="9bba0214ccf7f1079c5d59210045227bcf619519840ebfa80cd3849cff5a5bf2"

SRC_DIR="$CACHE_DIR/src"
TOOLS_DIR="$CACHE_DIR/tools"
BUILD_DIR="$SRC_DIR/wine-build-dxmt"
OUTPUT="$CACHE_DIR/dxmt-driver/winemac.so"
# configure needs Wine's MoltenVK/Vulkan libraries; use a link without spaces in the path
WINE_LIB_LINK="$CACHE_DIR/gcenx-lib"

if [ ! -d "$WINE_DIR/lib" ]; then
    echo "Error: Moonshine's Wine is not installed. Launch Moonshine and finish setup first."
    exit 1
fi

ensure_llvm_mingw

# macOS ships bison 2.3; Wine needs 3.0+
if [ ! -x "$TOOLS_DIR/bin/bison" ]; then
    fetch_verified "$BISON_URL" "$BISON_SHA256" "$SRC_DIR/bison-$BISON_VERSION.tar.xz"
    echo "==> Building bison $BISON_VERSION..."
    rm -rf "$SRC_DIR/bison-$BISON_VERSION" "$SRC_DIR/bison-build"
    tar -xf "$SRC_DIR/bison-$BISON_VERSION.tar.xz" -C "$SRC_DIR"
    mkdir -p "$SRC_DIR/bison-build"
    (cd "$SRC_DIR/bison-build" && "../bison-$BISON_VERSION/configure" --prefix="$TOOLS_DIR" --disable-nls >/dev/null && make -j8 >/dev/null && make install >/dev/null)
fi

fetch_verified "$WINE_URL" "$WINE_SHA256" "$SRC_DIR/wine-$WINE_VERSION.tar.xz"
fetch_verified "$STAGING_URL" "$STAGING_SHA256" "$SRC_DIR/wine-staging-$WINE_VERSION.tar.gz"

echo "==> Preparing Wine $WINE_VERSION source..."
WINE_SRC="$SRC_DIR/wine-$WINE_VERSION-dxmt"
rm -rf "$WINE_SRC" "$SRC_DIR/wine-staging-$WINE_VERSION" "$BUILD_DIR"
mkdir -p "$WINE_SRC"
tar -xf "$SRC_DIR/wine-$WINE_VERSION.tar.xz" -C "$WINE_SRC" --strip-components 1
tar -xzf "$SRC_DIR/wine-staging-$WINE_VERSION.tar.gz" -C "$SRC_DIR"
# The only Staging patch that affects winemac.so; the rest touch other modules
patch -d "$WINE_SRC" -p1 -s < "$SRC_DIR/wine-staging-$WINE_VERSION/patches/winemac.drv-no-flicker-patch/0001-winemac.drv-No-Flicker-patch.patch"
patch -d "$WINE_SRC" -p1 -s < "$PROJECT_DIR/patches/wine/winemac-dxmt.patch"

echo "==> Configuring (x86_64)..."
ln -sfn "$WINE_DIR/lib" "$WINE_LIB_LINK"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"
export PATH="$TOOLS_DIR/bin:$PATH"
# Xcode's clang targets arm64 by default even under Rosetta, so set the arch explicitly
arch -x86_64 "$WINE_SRC/configure" \
    --build=x86_64-apple-darwin \
    --enable-archs=x86_64 \
    --disable-tests \
    --with-mingw="$LLVM_MINGW_BIN/clang" \
    --with-coreaudio \
    --with-vulkan \
    --without-alsa --without-capi --without-cups --without-dbus --without-ffmpeg \
    --without-freetype --without-gnutls --without-gphoto --without-gssapi \
    --without-gstreamer --without-inotify --without-krb5 --without-netapi \
    --without-opencl --without-oss --without-pcap --without-pcsclite --without-pulse \
    --without-sane --without-sdl --without-udev --without-usb --without-v4l2 \
    --without-va --without-wayland --without-x \
    CC="/usr/bin/clang -arch x86_64" \
    CXX="/usr/bin/clang++ -arch x86_64" \
    OBJC="/usr/bin/clang -arch x86_64" \
    LDFLAGS="-L$WINE_LIB_LINK" \
    > configure.log 2>&1 || { echo "Error: configure failed, see $BUILD_DIR/configure.log"; exit 1; }

echo "==> Building winemac.so..."
arch -x86_64 make -j"$(sysctl -n hw.ncpu)" dlls/winemac.drv/winemac.so > make.log 2>&1 \
    || { echo "Error: build failed, see $BUILD_DIR/make.log"; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"
cp dlls/winemac.drv/winemac.so "$OUTPUT"
# Match Gcenx's install name, then sign
install_name_tool -id winemac.so "$OUTPUT"
codesign --force --sign - "$OUTPUT"

if ! nm -gU "$OUTPUT" | grep -q '_macdrv_functions$'; then
    echo "Error: built winemac.so does not export macdrv_functions"
    exit 1
fi

echo "==> Done! Built $OUTPUT"
