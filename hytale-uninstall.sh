#!/bin/bash
set -euo pipefail

# Hytale Server Uninstaller
# Supports keeping data or full removal

INSTANCE_ID="${INSTANCE_ID:-default}" # UUID for unique service names
SERVICE_NAME="hytale-server-${INSTANCE_ID}"
UNIT_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
SOCKET_FILE="/etc/systemd/system/${SERVICE_NAME}.socket"
RUNTIME_SOCKET="/run/${SERVICE_NAME}.socket"
DATA_DIR="${INSTALL_DIR:-/opt/hytale-${INSTANCE_ID}}"
USER_NAME="hytale-srv"
GROUP_NAME="hytale-srv"
KEEP_FILES="${KEEP_FILES:-false}"

usage() {
  cat <<'EOF'
Usage: INSTANCE_ID=<uuid> hytale-uninstall.sh [--keep-files]

Options:
  --keep-files   Keep /opt/hytale-<uuid> contents, user, and group
  -h, --help     Show this help

Required Env vars:
  INSTANCE_ID    UUID of the instance to uninstall (e.g., 16652474-c4a3-4b9a-8fb4-b1c7a5bb1681)

Optional Env vars:
  INSTALL_DIR    Override data dir (default: /opt/hytale-${INSTANCE_ID})
  KEEP_FILES     Set to true to preserve files/user/group

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
  shift || true

done

log() { echo "$1"; }

# 1) Stop service if running
if systemctl list-units --full -all | grep -q "${SERVICE_NAME}.service"; then
  log "[1] Stopping service ${SERVICE_NAME}"
  systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}" 2>/dev/null || true
else
  log "[1] Service ${SERVICE_NAME} not found"
fi

# 1.5) Stop and disable socket if running
if systemctl list-units --full -all | grep -q "${SERVICE_NAME}.socket"; then
  log "[1.5] Stopping socket ${SERVICE_NAME}.socket"
  systemctl stop "${SERVICE_NAME}.socket" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.socket" 2>/dev/null || true
else
  log "[1.5] Socket ${SERVICE_NAME}.socket not found"
fi

# 1b) Kill any remaining Java processes running as hytale-srv
if id "${USER_NAME}" &>/dev/null 2>&1; then
  log "[1b] Killing remaining Java processes for user ${USER_NAME}"
  pkill -9 -u "${USER_NAME}" 2>/dev/null || true
  sleep 1
fi

# 2) Remove systemd units
if [ -f "${UNIT_FILE}" ]; then
  log "[2] Removing systemd unit ${UNIT_FILE}"
  rm -f "${UNIT_FILE}"
else
  log "[2] Systemd unit not present"
fi

if [ -f "${SOCKET_FILE}" ]; then
  log "[2.5] Removing systemd socket unit ${SOCKET_FILE}"
  rm -f "${SOCKET_FILE}"
else
  log "[2.5] Systemd socket unit not present"
fi

# Reload systemd after removing units
systemctl daemon-reload 2>/dev/null || true

# 2.7) Remove runtime socket if it exists
if [ -S "${RUNTIME_SOCKET}" ]; then
  log "[2.7] Removing runtime socket ${RUNTIME_SOCKET}"
  rm -f "${RUNTIME_SOCKET}"
else
  log "[2.7] Runtime socket already removed"
fi

if [ "${KEEP_FILES}" = "true" ]; then
  log "[3] Keeping files and user/group as requested"
  log "    Data directory preserved at ${DATA_DIR}"
  exit 0
fi

# 3) Remove data directory
if [ -d "${DATA_DIR}" ]; then
  log "[3] Removing data directory ${DATA_DIR}"
  rm -rf "${DATA_DIR}"
else
  log "[3] Data directory already removed (${DATA_DIR})"
fi

# 4) Remove user and group if they exist
if id "${USER_NAME}" &>/dev/null; then
  log "[4] Removing user ${USER_NAME}"
  userdel -r "${USER_NAME}" 2>/dev/null || userdel "${USER_NAME}" || true
else
  log "[4] User ${USER_NAME} not present"
fi

if getent group "${GROUP_NAME}" >/dev/null; then
  log "[5] Removing group ${GROUP_NAME}"
  groupdel "${GROUP_NAME}" || true
else
  log "[5] Group ${GROUP_NAME} not present"
fi

log "✅ Uninstall complete"
