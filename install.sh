#!/bin/bash
# install.sh -- install the `baseline` command into PATH.
#
# Usage:
#   ./install.sh                # installs to /usr/local/bin/baseline (needs sudo)
#   PREFIX=$HOME/.local ./install.sh   # installs to $PREFIX/bin/baseline (no sudo)
#
# After install, run: baseline help

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/baseline"

if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: this toolkit is macOS-only." >&2
    exit 1
fi

[ -x "$SCRIPT_DIR/bin/baseline" ] || chmod +x "$SCRIPT_DIR/bin/baseline"
[ -x "$SCRIPT_DIR/scripts/memory-snapshot.sh" ] || chmod +x "$SCRIPT_DIR/scripts/memory-snapshot.sh"
[ -x "$SCRIPT_DIR/scripts/build-baseline-pdf.sh" ] || chmod +x "$SCRIPT_DIR/scripts/build-baseline-pdf.sh"

mkdir -p "$BIN_DIR" 2>/dev/null || sudo mkdir -p "$BIN_DIR"

echo "Linking $TARGET -> $SCRIPT_DIR/bin/baseline"
if [ -w "$BIN_DIR" ]; then
    ln -sf "$SCRIPT_DIR/bin/baseline" "$TARGET"
else
    sudo ln -sf "$SCRIPT_DIR/bin/baseline" "$TARGET"
fi

echo ""
echo "Installed. Try:"
echo "  baseline help"
echo ""
echo "Quick start:"
echo "  baseline start    # day 0"
echo "  baseline build    # day 14 (or whenever you have enough data)"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo ""
    echo "Note: $BIN_DIR is not in your PATH. Add this to your shell profile:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
