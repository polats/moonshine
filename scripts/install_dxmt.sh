#!/usr/bin/env bash
set -euo pipefail

# Installs DXMT (Direct3D 10/11 on Metal) into Moonshine's Wine, with the winemac.so
# built by build_winemac_dxmt.sh. This replaces Wine's d3d11, dxgi and d3d10core for
# every program in every bottle, since Wine always loads builtin DLLs from its own
# folder first. Wine's original files are backed up and restored by --uninstall.
#
# Usage:
#   ./scripts/install_dxmt.sh <bottle-path>...
#   ./scripts/install_dxmt.sh --uninstall <bottle-path>...
#
# Games that render too dark on HDR-capable (EDR) displays need a dxmt.conf next
# to their .exe containing:  dxgi.forceSDR = True

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

DXMT_VERSION="0.80"
DXMT_URL="https://github.com/3Shain/dxmt/releases/download/v$DXMT_VERSION/dxmt-v$DXMT_VERSION-builtin.tar.gz"
DXMT_SHA256="8f260e36b5739e68f3bad613381441385c4dc7b85b78ba8de653d5a6a264529d"

DRIVER="$CACHE_DIR/dxmt-driver/winemac.so"
BACKUP_DIR="$CACHE_DIR/backup/wine"
UNIX_DIR="$WINE_DIR/lib/wine/x86_64-unix"
WINDOWS_DIR="$WINE_DIR/lib/wine/x86_64-windows"
REPLACED_DLLS=(d3d11.dll dxgi.dll d3d10core.dll)

UNINSTALL=false
if [ "${1:-}" = "--uninstall" ]; then
    UNINSTALL=true
    shift
fi

if [ $# -lt 1 ]; then
    echo "Usage: $0 [--uninstall] <bottle-path>..."
    exit 1
fi

for bottle in "$@"; do
    if [ ! -d "$bottle/drive_c/windows/system32" ]; then
        echo "Error: $bottle is not a bottle"
        exit 1
    fi
done

require_wine_stopped

if $UNINSTALL; then
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "Error: no backup found in $BACKUP_DIR"
        exit 1
    fi
    echo "==> Restoring Wine's original files..."
    cp -p "$BACKUP_DIR/winemac.so" "$UNIX_DIR/winemac.so"
    for dll in "${REPLACED_DLLS[@]}"; do
        cp -p "$BACKUP_DIR/$dll" "$WINDOWS_DIR/$dll"
    done
    rm -f "$UNIX_DIR/winemetal.so" "$WINDOWS_DIR/winemetal.dll"
    for bottle in "$@"; do
        rm -f "$bottle/drive_c/windows/system32/winemetal.dll"
    done
    echo "==> Done! DXMT removed."
    exit 0
fi

if [ ! -f "$DRIVER" ]; then
    echo "Error: $DRIVER not found. Run ./scripts/build_winemac_dxmt.sh first."
    exit 1
fi

fetch_verified "$DXMT_URL" "$DXMT_SHA256" "$CACHE_DIR/dxmt-v$DXMT_VERSION-builtin.tar.gz"
DXMT_DIR="$CACHE_DIR/dxmt-v$DXMT_VERSION"
rm -rf "$DXMT_DIR"
mkdir -p "$DXMT_DIR"
tar -xzf "$CACHE_DIR/dxmt-v$DXMT_VERSION-builtin.tar.gz" -C "$DXMT_DIR" --strip-components 1

# Back up only Wine's own files, never a previous install of ours (e.g. on a re-run or
# after rebuilding the driver), so the backup always holds the originals
backup() {
    mkdir -p "$BACKUP_DIR"
    cp -p "$1" "$BACKUP_DIR/$(basename "$1")"
}

echo "==> Backing up Wine's original files to $BACKUP_DIR..."
if ! nm -gU "$UNIX_DIR/winemac.so" | grep -q '_macdrv_functions$'; then
    backup "$UNIX_DIR/winemac.so"
fi
for dll in "${REPLACED_DLLS[@]}"; do
    if ! grep -qai dxmt "$WINDOWS_DIR/$dll"; then
        backup "$WINDOWS_DIR/$dll"
    fi
done

echo "==> Installing DXMT $DXMT_VERSION..."
cp "$DRIVER" "$UNIX_DIR/winemac.so"
cp "$DXMT_DIR/x86_64-unix/winemetal.so" "$UNIX_DIR/winemetal.so"
codesign --force --sign - "$UNIX_DIR/winemetal.so"
cp "$DXMT_DIR/x86_64-windows/winemetal.dll" "$WINDOWS_DIR/winemetal.dll"
for dll in "${REPLACED_DLLS[@]}"; do
    cp "$DXMT_DIR/x86_64-windows/$dll" "$WINDOWS_DIR/$dll"
done
for bottle in "$@"; do
    cp "$DXMT_DIR/x86_64-windows/winemetal.dll" "$bottle/drive_c/windows/system32/winemetal.dll"
done

echo "==> Done! DXMT $DXMT_VERSION installed."
