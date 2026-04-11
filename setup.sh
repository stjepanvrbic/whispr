#!/bin/bash
set -euo pipefail

# ---------------------------------------------------------------------------
# whispr setup — installs everything from scratch on a fresh macOS machine
# ---------------------------------------------------------------------------

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

WHISPR_DIR="$HOME/.whispr"
APP_BUNDLE="$WHISPR_DIR/Whispr.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_BIN="$APP_MACOS/whispr-engine"
BUNDLE_ID="com.whispr.daemon"
CODESIGN_IDENTITY="whispr-cert"
PLIST_LABEL="$BUNDLE_ID"
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
# Swift toolchain
# ---------------------------------------------------------------------------
if ! command -v swift &>/dev/null; then
    error "Swift is required. Install Xcode or Xcode Command Line Tools:\n  xcode-select --install"
fi

# ---------------------------------------------------------------------------
# Build whispr-engine
# ---------------------------------------------------------------------------
info "Building whispr-engine (this takes ~60s on first run)..."
swift build --package-path "$SCRIPT_DIR/engine" -c release --product whispr-engine 2>&1 | tail -1
ENGINE_BIN=$(swift build --package-path "$SCRIPT_DIR/engine" -c release --product whispr-engine --show-bin-path 2>/dev/null)/whispr-engine

# ---------------------------------------------------------------------------
# Create .app bundle (accessibility permission persists across binary updates)
# ---------------------------------------------------------------------------
FIRST_INSTALL=false
if [ ! -f "$APP_BUNDLE/Contents/Info.plist" ]; then
    FIRST_INSTALL=true
fi

mkdir -p "$APP_MACOS"
mkdir -p "$WHISPR_DIR"
# Record where we built from — the in-app "Update Whispr" action reads
# this to find the clone it should `git pull && bash setup.sh` next time.
echo "$SCRIPT_DIR" > "$WHISPR_DIR/source_path"
cp "$ENGINE_BIN" "$APP_BIN"
chmod +x "$APP_BIN"

# Write Info.plist with stable bundle ID
cat > "$APP_BUNDLE/Contents/Info.plist" <<INFOPLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>Whispr</string>
    <key>CFBundleExecutable</key>
    <string>whispr-engine</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Whispr needs microphone access to transcribe your speech.</string>
</dict>
</plist>
INFOPLIST

# ---------------------------------------------------------------------------
# Code signing with a stable self-signed certificate
# ---------------------------------------------------------------------------
# macOS TCC (Accessibility permission) validates against the binary's
# Designated Requirement. Ad-hoc signing uses the CDHash, which changes on
# every rebuild — invalidating the permission. A stable self-signed cert
# produces a DR like `identifier "com.whispr.daemon" and anchor trusted`
# which stays the same across rebuilds, so the permission persists.
# This is the same pattern yabai/skhd use.

ensure_codesign_cert() {
    local LOGIN_KC="$HOME/Library/Keychains/login.keychain-db"

    # Use `find-identity` without -v (which filters for trusted only); self-signed
    # certs are not "trusted" but still work with codesign.
    if security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null | grep -q "\"$CODESIGN_IDENTITY\""; then
        return 0
    fi

    info "Creating self-signed code signing certificate '$CODESIGN_IDENTITY'..."

    local TMP
    TMP=$(mktemp -d)

    cat > "$TMP/openssl.cnf" <<EOF
[ req ]
distinguished_name = req_dn
prompt             = no
x509_extensions    = v3_codesign

[ req_dn ]
CN = $CODESIGN_IDENTITY

[ v3_codesign ]
basicConstraints     = critical, CA:FALSE
keyUsage             = critical, digitalSignature
extendedKeyUsage     = critical, codeSigning
subjectKeyIdentifier = hash
EOF

    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -config "$TMP/openssl.cnf" -extensions v3_codesign \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1

    # -legacy is required on macOS — the default OpenSSL 3 format can't be
    # imported by `security`.
    openssl pkcs12 -export -legacy \
        -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -name "$CODESIGN_IDENTITY" -out "$TMP/cert.p12" \
        -passout pass:whispr >/dev/null 2>&1

    security import "$TMP/cert.p12" -k "$LOGIN_KC" -P whispr -A >/dev/null

    rm -rf "$TMP"

    if security find-identity -p codesigning "$LOGIN_KC" 2>/dev/null | grep -q "\"$CODESIGN_IDENTITY\""; then
        info "Certificate created ✓"
    else
        error "Certificate creation failed"
    fi
}

# Detect if the cert existed before this run — if we just created it,
# the bundle identity changed and stale TCC entries must be cleared.
CERT_WAS_NEW=false
if ! security find-identity -p codesigning "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | grep -q "\"$CODESIGN_IDENTITY\""; then
    CERT_WAS_NEW=true
fi

ensure_codesign_cert
codesign -fs "$CODESIGN_IDENTITY" --identifier "$BUNDLE_ID" "$APP_BUNDLE" 2>&1
info "App bundle signed with '$CODESIGN_IDENTITY'"

# If this is the first time we're signing with the stable cert (either a
# brand-new install or a transition from an older ad-hoc/unsigned build),
# clear stale TCC entries so the user gets fresh permission prompts.
if [ "$CERT_WAS_NEW" = "true" ]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    tccutil reset Microphone "$BUNDLE_ID" >/dev/null 2>&1 || true
    info "Cleared stale permission grants (first install with stable identity)"
fi

info "whispr-engine ✓"

# ---------------------------------------------------------------------------
# Install config
# ---------------------------------------------------------------------------
if [ ! -f "$WHISPR_DIR/config.json" ]; then
    cp "$SCRIPT_DIR/config.json" "$WHISPR_DIR/config.json"
    info "Config → $WHISPR_DIR/config.json"
else
    info "Existing config preserved"
fi

# ---------------------------------------------------------------------------
# LaunchAgent — points to binary inside the .app bundle
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
        <string>${APP_BIN}</string>
    </array>
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

# Stop any running daemon — retry because bootout can take a moment to complete
launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
for i in 1 2 3 4 5; do
    if ! launchctl print "gui/$(id -u)/$PLIST_LABEL" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

# Start the daemon
launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>&1
launchctl enable "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
launchctl kickstart -k "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || true
info "LaunchAgent installed and started ✓"

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
info "whispr is installed and the daemon is starting!"
echo ""
echo "  FIRST-TIME SETUP — two permission dialogs will appear:"
echo ""
echo "  1. ACCESSIBILITY: macOS will ask to let Whispr control your computer."
echo "     → Click 'Open System Settings' in the dialog"
echo "     → Toggle ON the switch next to 'Whispr'"
echo "     → whispr detects this automatically — no restart needed"
echo "     → This permission persists across updates."
echo ""
echo "  2. MICROPHONE: macOS will ask to let Whispr access the microphone."
echo "     → Click 'OK' to allow"
echo ""
echo "  After permissions are granted, the Nemotron speech model downloads"
echo "  automatically (~600 MB) and warms up CoreML. This only happens once."
echo ""
echo "  Once complete, look for the waveform icon in your menu bar —"
echo "  click it to access Preferences, toggle on/off, or trigger an update."
echo ""
echo "  Hold Option to record, release to transcribe, press Escape to cancel."
echo ""
echo "  Watch progress:  tail -f /tmp/whispr.log"
echo "  Config:          $WHISPR_DIR/config.json  (or use Preferences in the menu)"
echo "  Reinstall/update: bash $0                 (or use Update Whispr in the menu)"
echo "  Uninstall:        bash $0 --uninstall"
