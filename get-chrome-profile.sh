#!/bin/bash
# =============================================================================
# get-chrome-profile.sh
# One-time script: log into YouTube via visible browser, save Chrome profile.
#
# UPDATED:
# - Stores profile in CURRENT directory (visible in VS Code)
# - Excludes socket files that break the zip command
# - Fixes permissions (root -> user)
# =============================================================================

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

log()     { echo -e "${GREEN}[$(date +'%H:%M:%S')]${NC} $1"; }
warning() { echo -e "${YELLOW}[$(date +'%H:%M:%S')] WARNING:${NC} $1"; }
error()   { echo -e "${RED}[$(date +'%H:%M:%S')] ERROR:${NC} $1"; exit 1; }
info()    { echo -e "${CYAN}[$(date +'%H:%M:%S')] INFO:${NC} $1"; }

# ----------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------
# Use current directory so the folder is visible in VS Code explorer
WORK_DIR="$(pwd)"
PROFILE_DIR="${WORK_DIR}/chrome-yt-profile"
PROFILE_ZIP="${WORK_DIR}/chrome-yt-profile.zip"
NOVNC_PORT=6080
DISP=":99"

echo ""
echo "============================================="
echo "   YouTube Chrome Profile Setup"
echo "============================================="
echo ""

# ----------------------------------------------------------------
# 1. Install dependencies
# ----------------------------------------------------------------
log "Installing dependencies..."
sudo apt-get update -qq 2>&1 | grep -v "^W:" | grep -v "^N:" || true
sudo apt-get install -y -qq \
    xvfb \
    x11vnc \
    novnc \
    websockify \
    zip \
    curl \
    google-chrome-stable 2>/dev/null || true

# If chrome install failed above, try manual approach
if ! command -v google-chrome >/dev/null 2>&1; then
    log "Installing Google Chrome manually..."
    curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq google-chrome-stable
fi

# ----------------------------------------------------------------
# 2. Start virtual display & VNC
# ----------------------------------------------------------------
log "Starting virtual display ($DISP)..."
pkill -f "Xvfb $DISP" 2>/dev/null || true
Xvfb $DISP -screen 0 1280x800x24 &
XVFB_PID=$!
sleep 2

log "Starting VNC server..."
x11vnc -display $DISP -forever -nopw -quiet 2>/dev/null &
X11VNC_PID=$!

log "Starting noVNC (Port $NOVNC_PORT)..."
NOVNC_WEB=$(find /usr -name "vnc.html" -exec dirname {} \; 2>/dev/null | head -1)
[ -z "$NOVNC_WEB" ] && NOVNC_WEB="/usr/share/novnc"
websockify --web "$NOVNC_WEB" $NOVNC_PORT localhost:5900 2>/dev/null &
WEBSOCKIFY_PID=$!
sleep 2

# ----------------------------------------------------------------
# 3. Instructions
# ----------------------------------------------------------------
if [ -n "$CODESPACE_NAME" ]; then
    URL="https://${CODESPACE_NAME}-${NOVNC_PORT}.app.github.dev/vnc.html"
else
    HOST_IP=$(hostname -I | awk '{print $1}')
    URL="http://$HOST_IP:$NOVNC_PORT/vnc.html"
fi

echo ""
echo -e "${YELLOW}ACTION REQUIRED:${NC}"
echo "1. Go to VS Code PORTS tab -> Forward Port $NOVNC_PORT (if not auto-forwarded)"
echo "2. Open this URL in your local browser/phone:"
echo "   $URL"
echo "3. Log in to YouTube in the Linux window."
echo ""

# ----------------------------------------------------------------
# 4. Launch Chrome
# ----------------------------------------------------------------
# Clean previous profile if exists
rm -rf "$PROFILE_DIR"
mkdir -p "$PROFILE_DIR"

log "Launching Chrome..."
DISPLAY=$DISP google-chrome \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --user-data-dir="$PROFILE_DIR" \
    --no-first-run \
    --log-level=3 \
    "https://www.youtube.com" &
CHROME_PID=$!

# ----------------------------------------------------------------
# 5. Wait for User
# ----------------------------------------------------------------
read -p "$(echo -e "${GREEN}Press ENTER here once you are logged in...${NC}")" _

log "Closing Chrome to flush data..."
kill $CHROME_PID 2>/dev/null || true
sleep 5 # Wait for lock files to release

# ----------------------------------------------------------------
# 6. Zip safely (Excluding sockets)
# ----------------------------------------------------------------
log "Zipping profile to: $PROFILE_ZIP"
rm -f "$PROFILE_ZIP"

# Navigate to dir to avoid full path structure in zip
cd "$WORK_DIR" || exit 1

# ZIP EXCLUDING SOCKET FILES (This fixes your error)
# We exclude 'Singleton*' files which are sockets/locks causing "No such device"
zip -r -q "$PROFILE_ZIP" "chrome-yt-profile" -x "*Singleton*" "*Lock*"

# ----------------------------------------------------------------
# 7. Fix Permissions (Crucial if run with sudo)
# ----------------------------------------------------------------
if [ -n "$SUDO_USER" ]; then
    log "Fixing ownership for user $SUDO_USER..."
    chown -R "$SUDO_USER:$SUDO_USER" "$PROFILE_DIR" "$PROFILE_ZIP"
fi

# ----------------------------------------------------------------
# 8. Cleanup
# ----------------------------------------------------------------
kill $WEBSOCKIFY_PID $X11VNC_PID $XVFB_PID 2>/dev/null || true

PROFILE_SIZE=$(du -sh "$PROFILE_ZIP" | cut -f1)
echo ""
echo "============================================="
echo -e "${GREEN}SUCCESS!${NC}"
echo "Zip file created: $PROFILE_ZIP ($PROFILE_SIZE)"
echo "1. Right-click 'chrome-yt-profile.zip' in VS Code Explorer"
echo "2. Select 'Download'"
echo "============================================="