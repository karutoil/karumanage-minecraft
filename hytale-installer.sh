#!/bin/bash
set -euo pipefail

# Hytale Server Installer for LXC Containers
# Optimized for running inside LXC containers
# No systemd/socket setup needed - handled by panel orchestrator
#
# Required environment variables:
#   INSTANCE_ID - UUID of the instance (e.g., 16652474-c4a3-4b9a-8fb4-b1c7a5bb1681)
#
# Usage: INSTANCE_ID=<uuid> ./hytale-installer.sh
#
# Optional environment variables:
#   INSTALL_DIR - Installation directory (default: /srv/game)
#   PORT - Server port (default: 5520)
#   SERVER_NAME - Server name (default: "Hytale Server")
#   MAX_PLAYERS - Max players (default: 100)
#   SERVER_MOTD - Server message (default: "")
#   HEAP_MB - Java heap memory in MB (default: 6144)

INSTANCE_ID="${INSTANCE_ID:-default}"
INSTALL_DIR="${INSTALL_DIR:-/srv/game}"
PORT="${PORT:-5520}"
SERVER_NAME="${SERVER_NAME:-Hytale Server}"
MAX_PLAYERS="${MAX_PLAYERS:-100}"
SERVER_MOTD="${SERVER_MOTD:-}"
HEAP_MB="${HEAP_MB:-6144}"

log() { echo "[hytale] $1"; }
err() { echo "[hytale] ERROR: $1" >&2; }

log "Hytale Server Installer (LXC Container)"
log "Instance ID: $INSTANCE_ID"
log "Install directory: $INSTALL_DIR"
log "Heap memory: ${HEAP_MB}MB"
log ""

# Step 1: Update package manager
log "[1/6] Updating system packages"
if command -v apt-get &>/dev/null; then
  apt-get update -y -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
    curl unzip openjdk-25-jre-headless ca-certificates
elif command -v yum &>/dev/null; then
  yum install -y -q curl unzip java-25-openjdk-headless
else
  err "No supported package manager found (apt, yum)"
  exit 1
fi
log "    ✓ System dependencies installed"

# Step 2: Create directory structure
log "[2/6] Setting up directories"
mkdir -p "$INSTALL_DIR/AppFiles/Server"
mkdir -p "$INSTALL_DIR/logs"
touch "$INSTALL_DIR/logs/latest.log"
chmod 755 "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/logs"
log "    ✓ Directories created"

# Step 3: Verify Java
log "[3/6] Verifying Java runtime"
JAVA_BIN=$(which java || echo "")
if [ -z "$JAVA_BIN" ]; then
  err "Java not found in PATH"
  exit 1
fi
JAVA_VERSION=$($JAVA_BIN -version 2>&1 | head -1)
log "    ✓ Using: $JAVA_VERSION"

# Step 4: Download Hytale downloader
log "[4/6] Downloading Hytale downloader"
DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"
if ! curl -fsSL -o "$INSTALL_DIR/AppFiles/hytale-downloader.zip" "$DOWNLOADER_URL"; then
  err "Failed to download Hytale downloader"
  exit 1
fi

if ! unzip -q -o "$INSTALL_DIR/AppFiles/hytale-downloader.zip" -d "$INSTALL_DIR/AppFiles/"; then
  err "Failed to extract Hytale downloader"
  exit 1
fi

chmod +x "$INSTALL_DIR/AppFiles/hytale-downloader-linux-amd64"
log "    ✓ Hytale downloader ready"

# Step 5: Download game files
log "[5/6] Downloading Hytale server files"
log "    (This requires authentication - browser will open)"
cd "$INSTALL_DIR/AppFiles/" || exit 1
./hytale-downloader-linux-amd64 -download-path "$INSTALL_DIR/AppFiles/hytale-server.zip" || {
  err "Download failed - ensure authentication completed"
  exit 1
}
cd - > /dev/null || exit 1

if [ -f "$INSTALL_DIR/AppFiles/hytale-server.zip" ]; then
  if ! unzip -q -o "$INSTALL_DIR/AppFiles/hytale-server.zip" -d "$INSTALL_DIR/AppFiles/"; then
    err "Failed to extract server archive"
    exit 1
  fi
  rm -f "$INSTALL_DIR/AppFiles/hytale-server.zip"
fi

# Validate server installation
if [ ! -f "$INSTALL_DIR/AppFiles/Server/HytaleServer.jar" ]; then
  err "HytaleServer.jar not found - download may have failed"
  exit 1
fi

log "    ✓ Hytale server files downloaded and extracted"

# Step 6: Create configuration
log "[6/6] Creating server configuration"

# Create config.json
cat > "$INSTALL_DIR/AppFiles/Server/config.json" << EOF
{
  "ServerName": "$SERVER_NAME",
  "MOTD": "$SERVER_MOTD",
  "Password": "",
  "MaxPlayers": $MAX_PLAYERS,
  "MaxViewRadius": 32,
  "Defaults": {
    "World": "default",
    "GameMode": "Adventure"
  }
}
EOF

# Create startup environment file for reference
cat > "$INSTALL_DIR/server.env" << EOF
# Hytale Server Environment
# Sourced by orchestrator (panel/agent)

INSTANCE_ID=$INSTANCE_ID
INSTALL_DIR=$INSTALL_DIR
PORT=$PORT
SERVER_NAME=$SERVER_NAME
MAX_PLAYERS=$MAX_PLAYERS
HEAP_MB=$HEAP_MB

# Java version
JAVA_BIN=$JAVA_BIN
EOF

log "    ✓ Configuration created"

log ""
log "✅ Installation Complete!"
log ""
log "📋 Next Steps:"
log "   • Instance is ready to start via panel"
log "   • Server will listen on UDP port $PORT"
log "   • Logs available at: $INSTALL_DIR/logs/latest.log"
log ""
log "📖 Configuration:"
log "   • Server config: $INSTALL_DIR/AppFiles/Server/config.json"
log "   • Environment: $INSTALL_DIR/server.env"
log ""
log "🚀 The orchestrator will automatically:"
log "   • Start/stop the Java process"
log "   • Stream console output"
log "   • Collect metrics (CPU, memory)"
log "   • Handle graceful shutdown"
log ""
