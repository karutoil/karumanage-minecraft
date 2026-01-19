#!/bin/bash
set -euo pipefail

# Multi-Variant Minecraft Server Installer
# Supports: Paper, Forge, Fabric, Geyser, Velocity, etc.
# 
# Required environment variables:
#   INSTANCE_ID - UUID of the instance
#   INSTALLER_TYPE - Type of installer (paper, forge, fabric, geyser, velocity)
#   MINECRAFT_VERSION - Minecraft version (e.g., 1.21.1, 1.20.4, 1.18.2)
#
# Optional environment variables:
#   BUILD_NUMBER - Specific build number (for Paper, Geyser, Velocity)
#   INSTALLER_URL - Direct URL to installer/server JAR (overrides auto-detection)
#   JAR_CHECKSUM - SHA256 checksum for verification
#   INSTALL_DIR - Installation directory (default: /opt/minecraft-${INSTANCE_ID})
#   PORT - Server port (default: 25565)
#   WORLD_NAME - World name (default: world)
#   MAX_PLAYERS - Max players (default: 20)
#   SERVER_MOTD - Server message (default: "A Minecraft Server")
#   HEAP_MB - Java heap memory in MB (default: 2048)

INSTALLER_TYPE="${INSTALLER_TYPE:-paper}"
MINECRAFT_VERSION="${MINECRAFT_VERSION:-1.21.1}"
BUILD_NUMBER="${BUILD_NUMBER:-latest}"
INSTALLER_URL="${INSTALLER_URL:-}"
JAR_CHECKSUM="${JAR_CHECKSUM:-}"
INSTANCE_ID="${INSTANCE_ID:-default}"
INSTALL_DIR="${INSTALL_DIR:-/opt/minecraft-${INSTANCE_ID}}"
MINECRAFT_USER="minecraft-srv"
MINECRAFT_GROUP="minecraft-srv"
SERVICE_NAME="minecraft-server-${INSTANCE_ID}"

# Function to get the latest Paper build
get_paper_url() {
  local version="$1"
  local build="${2:-latest}"
  
  echo "    → Fetching Paper build information for ${version}..."
  
  # Fetch version info
  local version_info
  version_info=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${version}" 2>/dev/null) || {
    echo "    ✗ Failed to fetch Paper version info for ${version}"
    exit 1
  }
  
  if [ "$build" = "latest" ]; then
    # Get latest build number from JSON response
    build=$(echo "$version_info" | grep -oP '"builds":\[\K[0-9]+' | tail -1 | tr -d '\n\r\t ')
  fi
  
  if [ -z "$build" ] || ! [[ "$build" =~ ^[0-9]+$ ]]; then
    echo "    ✗ Failed to get valid build number for Paper ${version} (got: '$build')"
    exit 1
  fi
  
  # Fetch build info
  local build_info
  build_info=$(curl -fsSL "https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build}" 2>/dev/null) || {
    echo "    ✗ Failed to fetch Paper build info for ${version} build ${build}"
    exit 1
  }
  
  # Extract download name - use multiple extraction methods for robustness
  local download_name
  download_name=$(echo "$build_info" | grep -oP '"name":"\K[^"]+' | head -1 | tr -d '\n\r\t ' | xargs)
  
  if [ -z "$download_name" ]; then
    # Fallback: construct filename from known pattern
    download_name="paper-${version}-${build}.jar"
  fi
  
  # Construct and validate URL
  local download_url="https://api.papermc.io/v2/projects/paper/versions/${version}/builds/${build}/downloads/${download_name}"
  
  # Ensure URL has no embedded whitespace
  download_url=$(echo "$download_url" | tr -d '\n\r\t ')
  
  # Basic URL validation: no spaces or invalid characters
  if [[ "$download_url" =~ [^a-zA-Z0-9./_:-] ]]; then
    echo "    ✗ Invalid characters in download URL"
    exit 1
  fi
  
  echo "$download_url"
}

# Function to get the latest Fabric installer
get_fabric_url() {
  local version="$1"
  echo "    → Fetching Fabric installer for ${version}..."
  
  # Validate that Fabric supports this version
  local fabric_versions
  fabric_versions=$(curl -fsSL "https://meta.fabricmc.net/v2/versions" 2>/dev/null | grep -oP '"version":"\K[^"]+' | head -20) || {
    echo "    ✗ Failed to fetch Fabric versions"
    exit 1
  }
  
  if ! echo "$fabric_versions" | grep -q "^${version}$"; then
    echo "    ✗ Fabric does not support Minecraft version ${version}"
    exit 1
  fi
  
  echo "https://meta.fabricmc.net/v2/versions/loader/${version}/stable/server/jar"
}

# Function to get the latest Forge installer
get_forge_url() {
  local version="$1"
  echo "    → Fetching Forge installer for ${version}..."
  
  # Get promotions data
  local promotions
  promotions=$(curl -fsSL "https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json" 2>/dev/null) || {
    echo "    ✗ Failed to fetch Forge promotions"
    exit 1
  }
  
  # Try latest, then recommended
  local forge_version
  forge_version=$(echo "$promotions" | grep -oP "\"${version}-latest\":\s*\"\K[^\"]+")
  forge_version=$(echo "$forge_version" | tr -d '\n\r\t ')
  
  if [ -z "$forge_version" ]; then
    forge_version=$(echo "$promotions" | grep -oP "\"${version}-recommended\":\s*\"\K[^\"]+")
    forge_version=$(echo "$forge_version" | tr -d '\n\r\t ')
  fi
  
  if [ -z "$forge_version" ]; then
    echo "    ✗ No Forge version found for Minecraft ${version}"
    exit 1
  fi
  
  echo "https://maven.minecraftforge.net/net/minecraftforge/forge/${version}-${forge_version}/forge-${version}-${forge_version}-installer.jar"
}

# Function to get Geyser standalone
get_geyser_url() {
  echo "    → Fetching Geyser standalone..."
  local build="${1:-latest}"
  
  if [ "$build" = "latest" ]; then
    local build_info
    build_info=$(curl -fsSL "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/latest" 2>/dev/null) || {
      echo "    ✗ Failed to fetch Geyser build info"
      exit 1
    }
    build=$(echo "$build_info" | grep -oP '"build":\K[0-9]+' | tr -d '\n\r\t ')
  fi
  
  if [ -z "$build" ] || ! [[ "$build" =~ ^[0-9]+$ ]]; then
    echo "    ✗ Failed to get valid Geyser build number"
    exit 1
  fi
  
  echo "https://download.geysermc.org/v2/projects/geyser/versions/latest/builds/${build}/downloads/geyser-standalone.jar"
}

# Function to get Velocity proxy
get_velocity_url() {
  local version="${1:-3.0}"
  echo "    → Fetching Velocity proxy for version ${version}..."
  
  local build_info
  build_info=$(curl -fsSL "https://api.papermc.io/v2/projects/velocity/versions/${version}/builds/latest" 2>/dev/null) || {
    echo "    ✗ Failed to fetch Velocity build info"
    exit 1
  }
  
  local download_name
  download_name=$(echo "$build_info" | grep -oP '"name":"\K[^"]+' | head -1 | tr -d '\n\r\t ')
  
  if [ -z "$download_name" ]; then
    download_name="velocity-${version}-SNAPSHOT.jar"
  fi
  
  echo "https://api.papermc.io/v2/projects/velocity/versions/${version}/builds/latest/downloads/${download_name}"
}

ensure_java() {
  local required_version="${1:-21}"
  
  if command -v java &>/dev/null; then
    local ver
    ver=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
    if [ "${ver:-0}" -ge "$required_version" ]; then
      echo "    ✓ Found Java ${ver}"
      return
    fi
  fi

  echo "    ⚠ Java <${required_version} detected - installing Temurin ${required_version} JRE"
  if command -v apt-get &>/dev/null; then
    install -d /usr/share/keyrings
    if ! [ -f /usr/share/keyrings/adoptium.gpg ]; then
      curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
    fi
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
      > /etc/apt/sources.list.d/adoptium.list
    apt-get update -y && apt-get install -y "temurin-${required_version}-jre" || apt-get install -y "openjdk-${required_version}-jre-headless" || apt-get install -y openjdk-17-jre-headless
  elif command -v yum &>/dev/null; then
    yum install -y "java-${required_version}-openjdk-headless" || yum install -y java-17-openjdk-headless
  else
    echo "    ✗ Cannot install Java automatically"
    exit 1
  fi
  echo "    ✓ Java installed: $(java -version 2>&1 | head -1)"
}

echo "[*] Multi-Variant Minecraft Server Installer"
echo "    Installer Type: ${INSTALLER_TYPE}"
echo "    Minecraft Version: ${MINECRAFT_VERSION}"
echo ""

# Step 1: Create dedicated user and group
echo "[1] Setting up dedicated user: $MINECRAFT_USER"
mkdir -p "$INSTALL_DIR"
if ! id "$MINECRAFT_USER" &>/dev/null; then
  groupadd -r "$MINECRAFT_GROUP" || true
  useradd -r -g "$MINECRAFT_GROUP" -d "$INSTALL_DIR" -s /bin/false \
    -c "Minecraft Server" "$MINECRAFT_USER" || true
  echo "    ✓ Created user $MINECRAFT_USER"
else
  echo "    ✓ User $MINECRAFT_USER already exists"
fi

# Step 2: Create directory structure with secure permissions
echo "[2] Setting up directories with secure permissions"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/worlds"
mkdir -p "$INSTALL_DIR/logs"
mkdir -p "$INSTALL_DIR/plugins"
mkdir -p "$INSTALL_DIR/mods"
mkdir -p "$INSTALL_DIR/config"
touch "$INSTALL_DIR/logs/latest.log"

chmod 750 "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/logs"
chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$INSTALL_DIR"

echo "    ✓ Directories created"

# Step 3: Determine installer URL and download
echo "[3] Downloading ${INSTALLER_TYPE} server JAR"

# Determine JAR filename based on type
case "$INSTALLER_TYPE" in
  paper)
    JAR_FILE="$INSTALL_DIR/paper-server.jar"
    [ -z "$INSTALLER_URL" ] && INSTALLER_URL=$(get_paper_url "$MINECRAFT_VERSION" "$BUILD_NUMBER")
    JAVA_VERSION=21
    ;;
  fabric)
    JAR_FILE="$INSTALL_DIR/fabric-server.jar"
    [ -z "$INSTALLER_URL" ] && INSTALLER_URL=$(get_fabric_url "$MINECRAFT_VERSION")
    JAVA_VERSION=21
    ;;
  forge)
    JAR_FILE="$INSTALL_DIR/forge-installer.jar"
    [ -z "$INSTALLER_URL" ] && INSTALLER_URL=$(get_forge_url "$MINECRAFT_VERSION")
    JAVA_VERSION=17
    ;;
  geyser)
    JAR_FILE="$INSTALL_DIR/geyser-standalone.jar"
    [ -z "$INSTALLER_URL" ] && INSTALLER_URL=$(get_geyser_url "$BUILD_NUMBER")
    JAVA_VERSION=17
    ;;
  velocity)
    JAR_FILE="$INSTALL_DIR/velocity.jar"
    [ -z "$INSTALLER_URL" ] && INSTALLER_URL=$(get_velocity_url "$MINECRAFT_VERSION")
    JAVA_VERSION=17
    ;;
  *)
    echo "    ✗ Unsupported installer type: $INSTALLER_TYPE"
    echo "    Supported: paper, fabric, forge, geyser, velocity"
    exit 1
    ;;
esac

echo "    → Downloading from: $INSTALLER_URL"

# Trim any whitespace from URL
INSTALLER_URL=$(echo "$INSTALLER_URL" | xargs)

# Validate URL before attempting download
if [ -z "$INSTALLER_URL" ] || ! [[ "$INSTALLER_URL" =~ ^https?:// ]]; then
  echo "    ✗ Invalid or empty installer URL: $INSTALLER_URL"
  exit 1
fi

# Download with retry logic
local retry_count=0
local max_retries=3
while [ $retry_count -lt $max_retries ]; do
  if curl -fL -o "$JAR_FILE" "$INSTALLER_URL" 2>/dev/null; then
    if [ -f "$JAR_FILE" ] && [ -s "$JAR_FILE" ]; then
      echo "    ✓ Downloaded $(ls -lh "$JAR_FILE" | awk '{print $5}')"
      break
    fi
  fi
  retry_count=$((retry_count + 1))
  if [ $retry_count -lt $max_retries ]; then
    echo "    ⚠ Download attempt $retry_count failed, retrying..."
    sleep 2
  fi
done

if [ ! -f "$JAR_FILE" ] || [ ! -s "$JAR_FILE" ]; then
  echo "    ✗ Failed to download JAR after $max_retries attempts"
  exit 1
fi

# Step 4: Verify checksum if provided
if [ -n "$JAR_CHECKSUM" ]; then
  echo "[4] Verifying JAR checksum"
  ACTUAL_CHECKSUM=$(sha256sum "$JAR_FILE" | awk '{print $1}')
  if [ "$ACTUAL_CHECKSUM" != "$JAR_CHECKSUM" ]; then
    echo "    ✗ Checksum mismatch!"
    echo "      Expected: $JAR_CHECKSUM"
    echo "      Got: $ACTUAL_CHECKSUM"
    rm -f "$JAR_FILE"
    exit 1
  fi
  echo "    ✓ Checksum verified"
fi

# Step 5: Special handling for Forge (needs installation)
if [ "$INSTALLER_TYPE" = "forge" ]; then
  echo "[5] Running Forge installer"
  ensure_java "$JAVA_VERSION"
  cd "$INSTALL_DIR"
  java -jar forge-installer.jar --installServer
  # Find the generated server JAR
  FORGE_JAR=$(find . -maxdepth 1 -name "forge-*-shim.jar" -o -name "forge-*.jar" | grep -v installer | head -1)
  if [ -z "$FORGE_JAR" ]; then
    echo "    ✗ Forge server JAR not found after installation"
    exit 1
  fi
  ln -sf "$FORGE_JAR" "$INSTALL_DIR/server.jar"
  JAR_FILE="$INSTALL_DIR/server.jar"
  echo "    ✓ Forge installed: $FORGE_JAR"
else
  # Step 5: Check/install Java
  echo "[5] Checking Java runtime"
  ensure_java "${JAVA_VERSION:-21}"
fi

JAVA_VERSION_ACTUAL=$(java -version 2>&1 | head -1)
echo "    ✓ Using: $JAVA_VERSION_ACTUAL"

# Step 6: Create systemd unit file
echo "[6] Creating systemd service unit"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
SOCKET_UNIT="/etc/systemd/system/${SERVICE_NAME}.socket"
RUNTIME_SOCKET="/run/${SERVICE_NAME}.socket"

# Determine startup command based on installer type
case "$INSTALLER_TYPE" in
  paper|fabric)
    START_CMD="/usr/bin/java -Xmx{{HEAP_MB}}M -Xms{{HEAP_MB}}M -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -jar $(basename "$JAR_FILE") nogui"
    ;;
  forge)
    START_CMD="/usr/bin/java -Xmx{{HEAP_MB}}M -Xms{{HEAP_MB}}M -XX:+UseG1GC @libraries/net/minecraftforge/forge/*/unix_args.txt nogui"
    ;;
  geyser)
    START_CMD="/usr/bin/java -Xmx{{HEAP_MB}}M -Xms{{HEAP_MB}}M -jar geyser-standalone.jar"
    ;;
  velocity)
    START_CMD="/usr/bin/java -Xmx{{HEAP_MB}}M -Xms{{HEAP_MB}}M -jar velocity.jar"
    ;;
esac

cat > "$SYSTEMD_UNIT" << 'EOF'
[Unit]
Description=Minecraft Server ({{INSTALLER_TYPE}})
Documentation=https://github.com/karutoil/karumanage
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=minecraft-srv
Group=minecraft-srv

# Socket input/output
Sockets={{SERVICE_NAME}}.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal
SyslogIdentifier={{SERVICE_NAME}}

# Security hardening
NoNewPrivileges=true
ProtectHome=yes

# Resource limits
MemoryLimit=4G
CPUQuota=200%
TasksMax=512
LimitNOFILE=65536

# Working directory and startup
WorkingDirectory={{INSTALL_DIR}}
ExecStart={{START_CMD}}

# Graceful shutdown
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=30

# Restart policy
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

cat > "$SOCKET_UNIT" << 'EOF'
[Unit]
Description=Minecraft Server Console Socket
BindsTo={{SERVICE_NAME}}.service

[Socket]
ListenFIFO={{RUNTIME_SOCKET}}
Service={{SERVICE_NAME}}.service
RemoveOnStop=true
SocketMode=0660
SocketUser=minecraft-srv
SocketGroup=minecraft-srv

[Install]
WantedBy=sockets.target
EOF

# Replace template variables
sed -i "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" "$SYSTEMD_UNIT"
sed -i "s|{{HEAP_MB}}|${HEAP_MB:-2048}|g" "$SYSTEMD_UNIT"
sed -i "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" "$SYSTEMD_UNIT"
sed -i "s|{{INSTALLER_TYPE}}|$INSTALLER_TYPE|g" "$SYSTEMD_UNIT"
sed -i "s|{{START_CMD}}|$START_CMD|g" "$SYSTEMD_UNIT"
sed -i "s|{{RUNTIME_SOCKET}}|$RUNTIME_SOCKET|g" "$SOCKET_UNIT"
sed -i "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" "$SOCKET_UNIT"

echo "    ✓ Created $SYSTEMD_UNIT"
echo "    ✓ Created $SOCKET_UNIT"

# Step 7: Create eula.txt
echo "[7] Accepting Minecraft EULA"
cat > "$INSTALL_DIR/eula.txt" << 'EOF'
# Minecraft EULA - see https://account.mojang.com/documents/minecraft_eula
eula=true
EOF
chown "$MINECRAFT_USER:$MINECRAFT_GROUP" "$INSTALL_DIR/eula.txt"
chmod 640 "$INSTALL_DIR/eula.txt"
echo "    ✓ EULA accepted"

# Step 8: Create configuration files based on installer type
echo "[8] Creating configuration files"
if [ "$INSTALLER_TYPE" != "velocity" ] && [ "$INSTALLER_TYPE" != "geyser" ]; then
  cat > "$INSTALL_DIR/server.properties" << 'EOF'
# Minecraft Server Properties
server-port={{PORT}}
server-ip=0.0.0.0
level-name={{WORLD_NAME}}
max-players={{MAX_PLAYERS}}
online-mode=true
pvp=true
difficulty=1
gamemode=0
motd={{SERVER_MOTD}}
EOF
  
  sed -i "s|{{PORT}}|${PORT:-25565}|g" "$INSTALL_DIR/server.properties"
  sed -i "s|{{WORLD_NAME}}|${WORLD_NAME:-world}|g" "$INSTALL_DIR/server.properties"
  sed -i "s|{{MAX_PLAYERS}}|${MAX_PLAYERS:-20}|g" "$INSTALL_DIR/server.properties"
  sed -i "s|{{SERVER_MOTD}}|${SERVER_MOTD:-A Minecraft Server}|g" "$INSTALL_DIR/server.properties"
  
  chown "$MINECRAFT_USER:$MINECRAFT_GROUP" "$INSTALL_DIR/server.properties"
  chmod 640 "$INSTALL_DIR/server.properties"
fi

echo "    ✓ Configuration files created"

# Step 9: Set JAR permissions
chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$INSTALL_DIR"
chmod 640 "$JAR_FILE"
echo "    ✓ Set permissions"

# Step 10: Reload systemd and show status
echo "[10] Finalizing systemd configuration"
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service 2>/dev/null || true
systemctl enable ${SERVICE_NAME}.socket 2>/dev/null || true
systemctl start ${SERVICE_NAME}.socket 2>/dev/null || true
echo "    ✓ Systemd configured"

echo ""
echo "✅ Installation Complete!"
echo ""
echo "📋 Details:"
echo "   Installer Type: ${INSTALLER_TYPE}"
echo "   Minecraft Version: ${MINECRAFT_VERSION}"
echo "   Installation Directory: ${INSTALL_DIR}"
echo ""
echo "📋 Next Steps:"
echo "   1. Start: sudo systemctl start ${SERVICE_NAME}"
echo "   2. Check logs: sudo journalctl -u ${SERVICE_NAME} -f"
echo "   3. Send commands via socket: echo 'help' | sudo nc -U ${RUNTIME_SOCKET}"
echo ""
echo "🔒 Security: Running as non-root user with restricted permissions"
echo ""
