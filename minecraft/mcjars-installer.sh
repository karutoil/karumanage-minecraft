#!/usr/bin/env bash
set -euo pipefail

# Minecraft installer using MCJars API
# Required env/vars (from game definition installer.variables or instance env):
#   MCJARS_API   - Base API URL (default: https://mcjars.app/api)
#   GAME_FLAVOR  - Distribution (paper|fabric|forge|purpur|folia|velocity, etc.)
#   MC_VERSION   - Minecraft version (e.g., 1.21.1)
#   BUILD        - Build number or "latest"
# Optional:
#   JAVA_FLAGS   - e.g., "-Xms2G -Xmx2G"
#   EULA         - Set to TRUE to auto-accept EULA
#   GAME_USER / GAME_GROUP - runtime ownership (default: minecraft-srv)

MCJARS_API="${MCJARS_API:-https://mcjars.app/api}"
GAME_FLAVOR="${GAME_FLAVOR:-paper}"
MC_VERSION="${MC_VERSION:-1.21.1}"
BUILD="${BUILD:-latest}"
JAVA_FLAGS="${JAVA_FLAGS:--Xms2G -Xmx2G}"
EULA="${EULA:-TRUE}"
GAME_ROOT="/opt/minecraft"
GAME_USER="${GAME_USER:-minecraft-srv}"
GAME_GROUP="${GAME_GROUP:-$GAME_USER}"
JAR_PATH="${GAME_ROOT}/server.jar"
LOG_DIR="${GAME_ROOT}/logs"
DATA_DIR="${GAME_ROOT}/data"
CONFIG_DIR="${GAME_ROOT}/config"

if [[ -z "$MCJARS_API" || -z "$GAME_FLAVOR" || -z "$MC_VERSION" || -z "$BUILD" ]]; then
  echo "ERROR: MCJARS_API, GAME_FLAVOR, MC_VERSION, and BUILD are required" >&2
  exit 1
fi

# Ensure directories
mkdir -p "$GAME_ROOT" "$LOG_DIR" "$DATA_DIR" "$CONFIG_DIR"

# Create user/group if missing
if ! getent group "$GAME_GROUP" >/dev/null; then
  groupadd --system "$GAME_GROUP"
fi
if ! id -u "$GAME_USER" >/dev/null 2>&1; then
  useradd --system --gid "$GAME_GROUP" --home "$GAME_ROOT" --shell /usr/sbin/nologin "$GAME_USER"
fi

# Build download URL (MCJars typically supports /flavor/version/build)
DOWNLOAD_URL="${MCJARS_API%/}/${GAME_FLAVOR}/${MC_VERSION}/${BUILD}"
TMP_JAR="/tmp/minecraft-${GAME_FLAVOR}-${MC_VERSION}-${BUILD}.jar"

echo "[mcjars] Downloading ${DOWNLOAD_URL}"
curl -fL "$DOWNLOAD_URL" -o "$TMP_JAR"

# Move into place
mv "$TMP_JAR" "$JAR_PATH"
chmod 755 "$JAR_PATH"
chown "$GAME_USER:$GAME_GROUP" "$JAR_PATH"

# Accept EULA if requested
if [[ "${EULA^^}" == "TRUE" ]]; then
  echo "eula=true" >"${GAME_ROOT}/eula.txt"
fi

# Seed minimal server.properties if missing
if [[ ! -f "${GAME_ROOT}/server.properties" ]]; then
  cat >"${GAME_ROOT}/server.properties" <<'EOF'
server-port=25565
motd=MCJars Server
max-players=20
online-mode=true
level-name=world
EOF
fi

# Record flags for runtime
echo "$JAVA_FLAGS" >"${GAME_ROOT}/java.flags"

# Ownership and perms
chown -R "$GAME_USER:$GAME_GROUP" "$GAME_ROOT"
chmod 755 "$GAME_ROOT"
chmod -R 755 "$GAME_ROOT"/logs "$GAME_ROOT"/data "$GAME_ROOT"/config

echo "[mcjars] Install complete: flavor=$GAME_FLAVOR version=$MC_VERSION build=$BUILD"
