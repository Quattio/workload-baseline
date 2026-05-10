#!/bin/bash
# install.sh -- install the `baseline` command into PATH.
#
# Two ways to use this:
#
#   1. One-liner (no clone needed -- this script downloads the toolkit):
#      curl -fsSL https://raw.githubusercontent.com/Quattio/macbook-baseline/main/install.sh | bash
#
#   2. Manual (after cloning or downloading the repo):
#      ./install.sh
#
# Defaults: installs `baseline` into /usr/local/bin (asks for sudo if needed).
# Override with PREFIX=$HOME/.local ./install.sh (no sudo, $HOME/.local/bin must be in PATH).

set -e

REPO_URL="https://github.com/Quattio/macbook-baseline.git"
TARBALL_URL="https://github.com/Quattio/macbook-baseline/archive/refs/heads/main.tar.gz"
BUNDLE_HOME="${BUNDLE_HOME:-$HOME/.local/share/macbook-baseline}"

if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: this toolkit is macOS-only." >&2
    exit 1
fi

# --- Detect mode: running from inside the bundle, or piped via curl? ---
SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "$SOURCE" ] && [ -f "$SOURCE" ] && [ -d "$(dirname "$SOURCE")/bin" ]; then
    # Running from inside the cloned/extracted bundle
    BUNDLE_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    echo "Installing from local bundle at $BUNDLE_DIR"
else
    # Piped via curl -- need to fetch the toolkit ourselves
    BUNDLE_DIR="$BUNDLE_HOME"
    if command -v git >/dev/null 2>&1; then
        if [ -d "$BUNDLE_DIR/.git" ]; then
            echo "Updating existing toolkit at $BUNDLE_DIR..."
            git -C "$BUNDLE_DIR" pull --quiet
        else
            echo "Cloning toolkit -> $BUNDLE_DIR"
            mkdir -p "$(dirname "$BUNDLE_DIR")"
            rm -rf "$BUNDLE_DIR"
            git clone --quiet "$REPO_URL" "$BUNDLE_DIR"
        fi
    else
        # Fallback: tarball download (works without git installed)
        echo "git not installed -- downloading tarball -> $BUNDLE_DIR"
        rm -rf "$BUNDLE_DIR"
        mkdir -p "$BUNDLE_DIR"
        curl -fsSL "$TARBALL_URL" | tar -xz --strip-components=1 -C "$BUNDLE_DIR"
    fi
fi

# --- Sanity check ---
if [ ! -x "$BUNDLE_DIR/bin/baseline" ]; then
    chmod +x "$BUNDLE_DIR/bin/baseline" 2>/dev/null || true
fi
if [ ! -f "$BUNDLE_DIR/bin/baseline" ]; then
    echo "ERROR: $BUNDLE_DIR/bin/baseline not found. Bundle layout looks broken." >&2
    exit 1
fi
chmod +x "$BUNDLE_DIR/scripts/"*.sh 2>/dev/null || true

# --- Install symlink ---
PREFIX="${PREFIX:-/usr/local}"
BIN_DIR="$PREFIX/bin"
TARGET="$BIN_DIR/baseline"

if ! mkdir -p "$BIN_DIR" 2>/dev/null; then
    sudo mkdir -p "$BIN_DIR"
fi

echo "Linking $TARGET -> $BUNDLE_DIR/bin/baseline"
if [ -w "$BIN_DIR" ]; then
    ln -sf "$BUNDLE_DIR/bin/baseline" "$TARGET"
else
    sudo ln -sf "$BUNDLE_DIR/bin/baseline" "$TARGET"
fi

echo ""
echo "Installed."
echo ""
echo "Try:"
echo "  baseline help"
echo ""
echo "Quick start:"
echo "  baseline start    # day 0  -- begin scheduled captures"
echo "  baseline build    # day 14 -- assemble the PDF report"

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
    echo ""
    echo "Note: $BIN_DIR is not in your PATH. Add this to your shell profile:"
    echo "  export PATH=\"$BIN_DIR:\$PATH\""
fi
