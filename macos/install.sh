#!/bin/bash
# install.sh -- install the `baseline` command into PATH (macOS).
#
# Two ways to use this:
#
#   1. One-liner (no clone needed -- this script downloads the toolkit):
#      curl -fsSL https://raw.githubusercontent.com/Quattio/workload-baseline/main/macos/install.sh | bash
#
#   2. Manual (after cloning or downloading the repo):
#      cd workload-baseline/macos
#      ./install.sh
#
# Defaults: installs `baseline` into /usr/local/bin (asks for sudo if needed).
# Override with PREFIX=$HOME/.local ./install.sh (no sudo, $HOME/.local/bin must be in PATH).

set -e

REPO_URL="https://github.com/Quattio/workload-baseline.git"
TARBALL_URL="https://github.com/Quattio/workload-baseline/archive/refs/heads/main.tar.gz"
REPO_HOME="${REPO_HOME:-$HOME/.local/share/workload-baseline}"

if [ "$(uname)" != "Darwin" ]; then
    echo "ERROR: macOS only. For Windows, see https://github.com/Quattio/workload-baseline/blob/main/windows/README.md" >&2
    exit 1
fi

# --- Detect mode: running from inside the macos/ folder, or piped via curl? ---
SOURCE="${BASH_SOURCE[0]:-}"
if [ -n "$SOURCE" ] && [ -f "$SOURCE" ] && [ -d "$(dirname "$SOURCE")/bin" ]; then
    # Running from inside the cloned/extracted macos/ folder
    BUNDLE_DIR="$(cd "$(dirname "$SOURCE")" && pwd)"
    echo "Installing from local macos/ folder at $BUNDLE_DIR"
else
    # Piped via curl -- need to fetch the toolkit ourselves
    if command -v git >/dev/null 2>&1; then
        if [ -d "$REPO_HOME/.git" ]; then
            echo "Updating existing toolkit at $REPO_HOME..."
            git -C "$REPO_HOME" pull --quiet
        else
            echo "Cloning toolkit -> $REPO_HOME"
            mkdir -p "$(dirname "$REPO_HOME")"
            rm -rf "$REPO_HOME"
            git clone --quiet "$REPO_URL" "$REPO_HOME"
        fi
    else
        # Fallback: tarball download (works without git installed)
        echo "git not installed -- downloading tarball -> $REPO_HOME"
        rm -rf "$REPO_HOME"
        mkdir -p "$REPO_HOME"
        curl -fsSL "$TARBALL_URL" | tar -xz --strip-components=1 -C "$REPO_HOME"
    fi
    BUNDLE_DIR="$REPO_HOME/macos"
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
