#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# whispr setup — installs everything from scratch on a fresh macOS machine
# ---------------------------------------------------------------------------

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

WHISPR_DIR="$HOME/.whispr"
PACKAGES_DIR="$WHISPR_DIR/packages"
MODELS_DIR="$WHISPR_DIR/models"
PLIST_LABEL="com.whispr.daemon"
PLIST_PATH="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MODEL="base.en"
MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-${MODEL}.bin"

info()  { echo -e "${GREEN}[whispr]${NC} $1"; }
warn()  { echo -e "${YELLOW}[whispr]${NC} $1"; }
error() { echo -e "${RED}[whispr]${NC} $1" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--uninstall" ]; then
    info "Uninstalling whispr..."
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    rm -rf "$WHISPR_DIR"
    info "Done. whisper-cpp and portaudio were left installed."
    exit 0
fi

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
[ "$(uname)" = "Darwin" ] || error "whispr requires macOS."

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
for pkg in whisper-cpp portaudio python@3; do
    if brew list "$pkg" &>/dev/null; then
        info "$pkg ✓"
    else
        info "Installing $pkg..."
        brew install "$pkg"
    fi
done

# ---------------------------------------------------------------------------
# Python packages (no venv — avoids macOS TCC identity confusion)
# ---------------------------------------------------------------------------
info "Installing Python packages..."
BREW_PREFIX="$(brew --prefix)"
PYTHON3="$BREW_PREFIX/bin/python3"
if [ ! -x "$PYTHON3" ]; then
    PYTHON3="$(command -v python3)" || error "Python 3 not found."
fi

mkdir -p "$WHISPR_DIR"
"$PYTHON3" -m pip install --quiet --target "$PACKAGES_DIR" -r "$SCRIPT_DIR/requirements.txt"
info "Python packages ✓"

# ---------------------------------------------------------------------------
# Whisper model
# ---------------------------------------------------------------------------
mkdir -p "$MODELS_DIR"
MODEL_FILE="$MODELS_DIR/ggml-${MODEL}.bin"
if [ -f "$MODEL_FILE" ]; then
    info "Model ggml-${MODEL}.bin ✓"
else
    info "Downloading ggml-${MODEL}.bin (~142 MB)..."
    curl -L --progress-bar -o "$MODEL_FILE" "$MODEL_URL"
    info "Model downloaded ✓"
fi

# ---------------------------------------------------------------------------
# Install whispr files
# ---------------------------------------------------------------------------
cp "$SCRIPT_DIR/whispr.py" "$WHISPR_DIR/whispr.py"
if [ ! -f "$WHISPR_DIR/config.yaml" ]; then
    cp "$SCRIPT_DIR/config.yaml" "$WHISPR_DIR/config.yaml"
    info "Default config written to $WHISPR_DIR/config.yaml"
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
echo "  On first launch, macOS will prompt you for:"
echo "    1. Accessibility  →  toggle on in the System Settings window that opens"
echo "    2. Microphone     →  click Allow when prompted"
echo ""
echo "  Configuration:  $WHISPR_DIR/config.yaml"
echo "  Logs:           /tmp/whispr.log"
echo "  Restart:        launchctl kickstart -k gui/\$(id -u)/$PLIST_LABEL"
echo "  Uninstall:      $SCRIPT_DIR/setup.sh --uninstall"
