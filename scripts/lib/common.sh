# Shared helpers for Moonshine scripts. Source, don't run.

CACHE_DIR="${MOONSHINE_CACHE_DIR:-$HOME/Library/Caches/Moonshine}"
WINE_DIR="${MOONSHINE_WINE_DIR:-$HOME/Library/Application Support/com.isaacmarovitz.Whisky/Libraries/Wine}"

LLVM_MINGW_VERSION="20261006"
LLVM_MINGW_NAME="llvm-mingw-$LLVM_MINGW_VERSION-ucrt-macos-universal"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/$LLVM_MINGW_VERSION/$LLVM_MINGW_NAME.tar.xz"
LLVM_MINGW_SHA256="a7a19b11048e89372637d26279cdb7c430ed3cf8c1e224310421312bf986ebf6"
LLVM_MINGW_BIN="$CACHE_DIR/$LLVM_MINGW_NAME/bin"

# fetch_verified <url> <sha256> <dest>: download unless already present, then check the hash
fetch_verified() {
    local url=$1 sha256=$2 dest=$3
    if [ ! -f "$dest" ]; then
        echo "==> Downloading $(basename "$dest")..."
        mkdir -p "$(dirname "$dest")"
        curl -fsSLo "$dest.part" "$url"
        mv "$dest.part" "$dest"
    fi
    echo "$sha256  $dest" | shasum -a 256 -c --quiet
}

ensure_llvm_mingw() {
    if [ ! -x "$LLVM_MINGW_BIN/x86_64-w64-mingw32-gcc" ]; then
        fetch_verified "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA256" "$CACHE_DIR/llvm-mingw.tar.xz"
        tar -xf "$CACHE_DIR/llvm-mingw.tar.xz" -C "$CACHE_DIR"
        rm "$CACHE_DIR/llvm-mingw.tar.xz"
    fi
}

require_wine_stopped() {
    if pgrep -f "$WINE_DIR/" >/dev/null; then
        echo "Error: Wine is running. Quit Steam and any programs in your bottles first."
        exit 1
    fi
}
