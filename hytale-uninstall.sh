#!/bin/bash
set -euo pipefail

# Hytale Server Uninstaller for LXC Containers
# Simplified for container environment
#
# Required environment variables:
#   INSTANCE_ID - UUID of the instance (e.g., 16652474-c4a3-4b9a-8fb4-b1c7a5bb1681)
#
# Usage: INSTANCE_ID=<uuid> ./hytale-uninstall.sh
#
# Optional environment variables:
#   INSTALL_DIR - Override data dir (default: /srv/game)
#   KEEP_FILES - Set to true to preserve game files

INSTANCE_ID="${INSTANCE_ID:-default}"
INSTALL_DIR="${INSTALL_DIR:-/srv/game}"
KEEP_FILES="${KEEP_FILES:-false}"

usage() {
  cat <<'EOF'
Usage: INSTANCE_ID=<uuid> hytale-uninstall.sh [--keep-files]

Options:
  --keep-files   Keep /srv/game contents for data preservation
  -h, --help     Show this help

Required Env vars:
  INSTANCE_ID    UUID of the instance (e.g., 16652474-c4a3-4b9a-8fb4-b1c7a5bb1681)

Optional Env vars:
  INSTALL_DIR    Override data dir (default: /srv/game)
  KEEP_FILES     Set to true to preserve files

Examples:
  INSTANCE_ID=abc123 ./hytale-uninstall.sh
  INSTANCE_ID=abc123 KEEP_FILES=true ./hytale-uninstall.sh --keep-files
EOF
}

for arg in "$@"; do
  case "$arg" in
    --keep-files) KEEP_FILES=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $arg"; usage; exit 1 ;;
  esac
done

log() { echo "[hytale] $1"; }

log "Hytale Server Uninstaller (LXC Container)"
log "Instance ID: $INSTANCE_ID"
log ""

# Step 1: Stop any running Java processes
log "[1/3] Stopping Hytale process"
if pgrep -f HytaleServer.jar > /dev/null 2>&1; then
  log "    Sending SIGTERM to HytaleServer.jar"
  pkill -15 -f HytaleServer.jar || true
  sleep 2
  
  # Force kill if still running
  if pgrep -f HytaleServer.jar > /dev/null 2>&1; then
    log "    Force killing remaining process"
    pkill -9 -f HytaleServer.jar || true
  fi
  log "    ✓ Process stopped"
else
  log "    ✓ No process running"
fi

# Step 2: Clean up temporary files
log "[2/3] Cleaning up temporary files"
if [ -d "$INSTALL_DIR/AppFiles" ]; then
  # Remove downloader and temp files but keep server JAR
  rm -f "$INSTALL_DIR/AppFiles/hytale-downloader.zip" 2>/dev/null || true
  rm -f "$INSTALL_DIR/AppFiles/hytale-downloader-linux-amd64" 2>/dev/null || true
  rm -f "$INSTALL_DIR/server.env" 2>/dev/null || true
  log "    ✓ Temporary files removed"
else
  log "    ✓ No temporary files to clean"
fi

# Step 3: Handle data preservation
if [ "$KEEP_FILES" = "true" ]; then
  log "[3/3] Preserving game files as requested"
  log "    ✓ Game data preserved at: $INSTALL_DIR"
  log ""
  log "✅ Uninstall complete (data preserved)"
  exit 0
fi

log "[3/3] Removing game files"
if [ -d "$INSTALL_DIR" ]; then
  rm -rf "$INSTALL_DIR"
  log "    ✓ Game directory removed"
else
  log "    ✓ Directory already removed"
fi

log ""
log "✅ Uninstall complete"
