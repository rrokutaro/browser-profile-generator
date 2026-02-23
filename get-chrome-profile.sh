#!/bin/bash
# =============================================================================
# get-chrome-profile.sh
# One-time script: log into YouTube via visible browser, save Chrome profile.
# Puppeteer will use this profile headlessly forever after.
#
# Designed for: GitHub Codespaces / any headless Linux machine
# FIXES: zip path issue, DBus noise suppressed, CRLF safe
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
PROFILE_DIR="${HOME}/.chrome-yt-profile"
PROFILE_ZIP="${HOME}/chrome-yt-profile.zip"
NOVNC_PORT=6080
DISP=":99"

echo ""
echo "============================================="
echo "   YouTube Chrome Profile Setup"
echo "============================================="
echo ""

# ----------------------------------------------------------------
# REGION CHECK
# ----------------------------------------------------------------
info "Checking your Codespace region..."
CURRENT_IP=$(curl -s https://api.ipify.org 2>/dev/null || echo "unknown")
CURRENT_REGION=$(curl -s "https://ipapi.co/${CURRENT_IP}/country_name/" 2>/dev/null || echo "unknown")
echo ""
echo "  Your current IP : $CURRENT_IP"
echo "  Detected region : $CURRENT_REGION"
echo ""
if [[ "$CURRENT_REGION" != "United States" ]]; then
    echo -e "${YELLOW}  ⚠  WARNING: Your Codespace is NOT in the US.${NC}"
    echo ""
    echo "  To get a US Codespace:"
    echo "  1. Delete this Codespace (github.com → your repo → Code → Codespaces → ··· → Delete)"
    echo "  2. Go to: https://github.com/settings/codespaces"
    echo "     Under 'Default region' pick: United States East / United States West"
    echo "  3. Create a NEW Codespace from your repo"
    echo ""
    read -p "$(echo -e "${YELLOW}Press ENTER to continue anyway, or Ctrl+C to abort and switch region...${NC}")" _
else
    log "Region OK: United States ✓"
fi
echo ""

# ----------------------------------------------------------------
# 1. Install dependencies
# ----------------------------------------------------------------
log "Removing broken apt sources..."
sudo rm -f /etc/apt/sources.list.d/yarn.list 2>/dev/null || true

log "Installing dependencies..."
sudo apt-get update -qq 2>&1 | grep -v "^W:" | grep -v "^N:" || true
sudo apt-get install -y -qq \
    xvfb \
    x11vnc \
    novnc \
    websockify \
    zip \
    curl 2>/dev/null

# Install Google Chrome if not present
if ! command -v google-chrome >/dev/null 2>&1; then
    log "Installing Google Chrome..."
    curl -fsSL https://dl-ssl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" | sudo tee /etc/apt/sources.list.d/google-chrome.list > /dev/null
    sudo apt-get update -qq 2>/dev/null
    sudo apt-get install -y -qq google-chrome-stable 2>/dev/null
else
    log "Chrome already installed: $(google-chrome --version)"
fi

# ----------------------------------------------------------------
# 2. Start virtual display
# ----------------------------------------------------------------
log "Starting virtual display ($DISP)..."
pkill -f "Xvfb $DISP" 2>/dev/null || true
sleep 1

Xvfb $DISP -screen 0 1280x800x24 &
XVFB_PID=$!
sleep 2

kill -0 $XVFB_PID 2>/dev/null || error "Xvfb failed to start"
log "Virtual display started (PID: $XVFB_PID)"

# ----------------------------------------------------------------
# 3. Start noVNC
# ----------------------------------------------------------------
log "Starting noVNC on port $NOVNC_PORT..."
pkill -f "x11vnc" 2>/dev/null || true
pkill -f "websockify" 2>/dev/null || true
sleep 1

x11vnc -display $DISP -forever -nopw -quiet 2>/dev/null &
X11VNC_PID=$!
sleep 2

NOVNC_WEB=$(find /usr -name "vnc.html" -exec dirname {} \; 2>/dev/null | head -1)
[ -z "$NOVNC_WEB" ] && NOVNC_WEB="/usr/share/novnc"

websockify --web "$NOVNC_WEB" $NOVNC_PORT localhost:5900 2>/dev/null &
WEBSOCKIFY_PID=$!
sleep 2

# ----------------------------------------------------------------
# 4. Print access instructions
# ----------------------------------------------------------------
echo ""
echo "============================================="
echo "  OPEN THIS IN YOUR PHONE BROWSER:"
echo "============================================="
echo ""
if [ -n "$CODESPACE_NAME" ]; then
    info "Codespaces detected — go to the PORTS tab in VS Code"
    info "Forward port $NOVNC_PORT then open:"
    info "https://${CODESPACE_NAME}-${NOVNC_PORT}.app.github.dev/vnc.html"
else
    HOST_IP=$(hostname -I | awk '{print $1}')
    info "http://$HOST_IP:$NOVNC_PORT/vnc.html"
fi
echo ""
echo "============================================="
echo "  WHAT TO DO:"
echo "============================================="
echo ""
echo "  1. You will see a Linux desktop"
echo "  2. Chrome will open automatically to YouTube"
echo "  3. Log into your Google/YouTube account"
echo "  4. Confirm you can see your YouTube feed"
echo "  5. Come back here and press ENTER"
echo ""
echo "============================================="
echo ""

# ----------------------------------------------------------------
# 5. Launch Chrome with persistent profile
# ----------------------------------------------------------------
mkdir -p "$PROFILE_DIR"
log "Launching Chrome with profile: $PROFILE_DIR"

DISPLAY=$DISP google-chrome \
    --no-sandbox \
    --disable-dev-shm-usage \
    --disable-gpu \
    --user-data-dir="$PROFILE_DIR" \
    --no-first-run \
    --no-default-browser-check \
    --log-level=3 \
    2>/dev/null \
    "https://www.youtube.com" &

CHROME_PID=$!
log "Chrome launched (PID: $CHROME_PID)"

# ----------------------------------------------------------------
# 6. Wait for user to log in
# ----------------------------------------------------------------
read -p "$(echo -e "${GREEN}Press ENTER once you have logged into YouTube...${NC}")" _

# ----------------------------------------------------------------
# 7. Flush and save profile
# ----------------------------------------------------------------
log "Closing Chrome cleanly so profile flushes to disk..."
kill $CHROME_PID 2>/dev/null || true
sleep 4  # Give Chrome time to write session data

# ----------------------------------------------------------------
# 8. Zip the profile  (FIX: use absolute paths, avoid cd issues)
# ----------------------------------------------------------------
log "Zipping Chrome profile..."

# Remove old zip if exists
rm -f "$PROFILE_ZIP"

# Zip using absolute path — avoids the "No such device or address" bug
zip -r -q "$PROFILE_ZIP" "$PROFILE_DIR"

if [ -f "$PROFILE_ZIP" ] && [ -s "$PROFILE_ZIP" ]; then
    PROFILE_SIZE=$(du -sh "$PROFILE_ZIP" | cut -f1)
    log "Profile zipped successfully: $PROFILE_ZIP ($PROFILE_SIZE)"
else
    error "Profile zip failed or is empty — check that $PROFILE_DIR exists and has content"
fi

# ----------------------------------------------------------------
# 9. Cleanup
# ----------------------------------------------------------------
log "Shutting down noVNC..."
kill $WEBSOCKIFY_PID 2>/dev/null || true
kill $X11VNC_PID 2>/dev/null || true
kill $XVFB_PID 2>/dev/null || true

# ----------------------------------------------------------------
# 10. Summary
# ----------------------------------------------------------------
echo ""
echo "============================================="
echo "  DONE"
echo "============================================="
echo ""
echo "  Profile dir : $PROFILE_DIR"
echo "  Profile zip : $PROFILE_ZIP ($PROFILE_SIZE)"
echo ""
echo "  NEXT STEPS:"
echo "  1. In VS Code file explorer, right-click chrome-yt-profile.zip"
echo "  2. Click Download"
echo "  3. Upload it to Google Drive"
echo "  4. Note the GDrive file ID from the share link"
echo "  5. Puppeteer uses this profile headlessly from here on"
echo ""
echo "============================================="
