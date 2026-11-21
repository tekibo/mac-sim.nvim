#!/bin/bash
set -euo pipefail

DEST_DIR="${XDG_BIN_HOME:-$HOME/.local/bin}"
VIEW_DEST="$DEST_DIR/mac-sim-view"
BASE_URL="https://raw.githubusercontent.com/tekibo/mac-sim.nvim/main/bin"
APP_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"

echo "==> Installing mac-sim binaries to $DEST_DIR..."
mkdir -p "$DEST_DIR"

install_file() {
  local name="$1"
  local dest="$DEST_DIR/$name"
  local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [ -f "$script_dir/bin/$name" ]; then
    cp "$script_dir/bin/$name" "$dest"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$BASE_URL/$name" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$BASE_URL/$name"
  else
    echo "Error: curl or wget required" >&2
    exit 1
  fi
  chmod +x "$dest"
}

install_file "mac-sim-view"
install_file "mac-sim-preview"

if ! command -v luajit >/dev/null 2>&1; then
  echo "==> Warning: 'luajit' not found in PATH. Please install LuaJIT via your package manager." >&2
fi

mkdir -p "$APP_DIR"
cat << 'DESKTOP' > "$APP_DIR/mac-sim.desktop"
[Desktop Entry]
Name=iOS Simulator
Comment=Native iOS Simulator viewer for macbox
Exec=mac-sim-view
Icon=phone
Terminal=false
Type=Application
Categories=Development;
DESKTOP

echo "==> mac-sim-view installed successfully!"
echo "==> Run: mac-sim-view"
