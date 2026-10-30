#!/usr/bin/env bash
set -euo pipefail

# Installs the steamwebhelper wrapper into a bottle's Steam install so the
# Steam UI renders under Wine (see scripts/steamwebhelper-wrapper/).
#
# Usage:
#   ./scripts/install_steam_wrapper.sh <bottle-path>
#
# Launch Steam with: -noverifyfiles -norepairfiles
# Otherwise Steam's startup check restores the original helper. Re-run this
# script after Steam updates itself.

if [ $# -ne 1 ]; then
    echo "Usage: $0 <bottle-path>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
SOURCE="$SCRIPT_DIR/steamwebhelper-wrapper/steamwebhelper-wrapper.c"
CEF_DIR="$1/drive_c/Program Files (x86)/Steam/bin/cef/cef.win64"
CC="$LLVM_MINGW_BIN/x86_64-w64-mingw32-gcc"

# Valve's helper is several MB; the wrapper is well under this
WRAPPER_SIZE_CEILING=500000

if [ ! -f "$CEF_DIR/steamwebhelper.exe" ]; then
    echo "Error: steamwebhelper.exe not found in $CEF_DIR"
    echo "Install Steam in the bottle and let it finish updating first."
    exit 1
fi

ensure_llvm_mingw

echo "==> Building wrapper..."
BUILD_DIR="$(mktemp -d)"
"$CC" -municode -O2 -Wall -Wextra -static -mwindows -o "$BUILD_DIR/steamwebhelper.exe" "$SOURCE"

TARGET="$CEF_DIR/steamwebhelper.exe"
REAL="$CEF_DIR/steamwebhelper_real.exe"

if [ "$(stat -f%z "$TARGET")" -ge "$WRAPPER_SIZE_CEILING" ]; then
    echo "==> Preserving Valve's helper as steamwebhelper_real.exe..."
    cp -p "$TARGET" "$REAL"
elif [ ! -f "$REAL" ] || [ "$(stat -f%z "$REAL")" -lt "$WRAPPER_SIZE_CEILING" ]; then
    echo "Error: Valve's original steamwebhelper.exe is missing. Reinstall Steam in the bottle."
    exit 1
fi

cp "$BUILD_DIR/steamwebhelper.exe" "$TARGET"
rm -rf "$BUILD_DIR"

echo "==> Done! Launch Steam with: -noverifyfiles -norepairfiles"
