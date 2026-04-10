#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# whispr setup — installs everything from scratch on a fresh macOS machine
# ---------------------------------------------------------------------------

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

WHISPR_DIR="$HOME/.whispr"
PACKAGES_DIR="$WHISPR_DIR/packages"
PLIST_LABEL="com.whispr.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

info()  { echo -e "${GREEN}[whispr]${NC} $1"; }
error() { echo -e "${RED}[whispr]${NC} $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    info "Uninstalling whispr..."
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    rm -rf "$WHISPR_DIR"
    info "Done."
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[ "$(uname)" = "Darwin" ] || error "whispr requires macOS 14+ on Apple Silicon."

# ---------------------------------------------------------------------------
# Homebrew
# ---------------------------------------------------------------------------
if ! command -v brew &>/dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [ -x /usr/local/bin/brew ]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# ---------------------------------------------------------------------------
# System dependencies
# ---------------------------------------------------------------------------
for pkg in python@3 portaudio; do
    if brew list "$pkg" &>/dev/null; then
        info "$pkg ✓"
    else
        info "Installing $pkg..."
        brew install "$pkg"
    fi
done

BREW_PREFIX="$(brew --prefix)"
PYTHON3="$BREW_PREFIX/bin/python3"
[ -x "$PYTHON3" ] || PYTHON3="$(command -v python3)" || error "Python 3 not found."

# ---------------------------------------------------------------------------
# Python packages (installed to ~/.whispr/packages, no venv needed)
# ---------------------------------------------------------------------------
info "Installing Python packages..."
mkdir -p "$WHISPR_DIR"
"$PYTHON3" -m pip install --quiet --target "$PACKAGES_DIR" -r "$SCRIPT_DIR/requirements.txt"
info "Python packages ✓"

# ---------------------------------------------------------------------------
# Swift engine (FluidAudio / Parakeet CoreML)
# ---------------------------------------------------------------------------
if ! command -v swift &>/dev/null; then
    error "Swift is required. Install Xcode or Xcode Command Line Tools:\n  xcode-select --install"
fi

info "Building whispr-engine (this takes ~60s on first run)..."
swift build -C "$SCRIPT_DIR/engine" -c release --product whispr-engine 2>&1 | tail -1
ENGINE_BIN=$(swift build -C "$SCRIPT_DIR/engine" -c release --product whispr-engine --show-bin-path 2>/dev/null)/whispr-engine
cp "$ENGINE_BIN" "$WHISPR_DIR/whispr-engine"
chmod +x "$WHISPR_DIR/whispr-engine"
info "whispr-engine ✓"

# ---------------------------------------------------------------------------
# Install whispr files
# ---------------------------------------------------------------------------
cp "$SCRIPT_DIR/whispr.py" "$WHISPR_DIR/whispr.py"
if [ ! -f "$WHISPR_DIR/config.yaml" ]; then
    cp "$SCRIPT_DIR/config.yaml" "$WHISPR_DIR/config.yaml"
    info "Default config → $WHISPR_DIR/config.yaml"
else
    info "Existing config preserved"
fi

# ---------------------------------------------------------------------------
# LaunchAgent
# ---------------------------------------------------------------------------
cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON3}</string>
        <string>${WHISPR_DIR}/whispr.py</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>PYTHONPATH</key>
        <string>${PACKAGES_DIR}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/whispr.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/whispr.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
info "LaunchAgent installed and started ✓"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
info "whispr is installed and running!"
echo ""
echo "  On first launch, macOS will prompt for Accessibility and Microphone."
echo "  The speech model downloads automatically on first use (~1.5 GB)."
echo ""
echo "  Config:     $WHISPR_DIR/config.yaml"
echo "  Logs:       /tmp/whispr.log"
echo "  Restart:    launchctl kickstart -k gui/\$(id -u)/$PLIST_LABEL"
echo "  Uninstall:  $SCRIPT_DIR/setup.sh --uninstall"
