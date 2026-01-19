#!/bin/bash
set -euo pipefail

# Hytale Server Installer
# Security-focused installation for Hytale dedicated servers
# 
# Required environment variables:
#   INSTANCE_ID - UUID of the instance (e.g., 16652474-c4a3-4b9a-8fb4-b1c7a5bb1681)
#
# Usage: INSTANCE_ID=<uuid> ./hytale-installer.sh
#
# Optional environment variables:
#   INSTALL_DIR - Installation directory (default: /opt/hytale-${INSTANCE_ID})
#   PORT - Server port (default: 5520)
#   SERVER_NAME - Server name (default: "Hytale Server")
#   MAX_PLAYERS - Max players (default: 100)
#   SERVER_MOTD - Server message (default: "")
#   HEAP_MB - Java heap memory in MB (default: 4096)

INSTANCE_ID="${INSTANCE_ID:-default}" # UUID for unique service names
INSTALL_DIR="${INSTALL_DIR:-/opt/hytale-${INSTANCE_ID}}"
HYTALE_USER="hytale-srv"
HYTALE_GROUP="hytale-srv"
SERVICE_NAME="hytale-server-${INSTANCE_ID}"

ensure_java() {
  if command -v java &>/dev/null; then
    local ver
    ver=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
    if [ "${ver:-0}" -eq 25 ]; then
      echo "    ✓ Found Java ${ver}"
      return
    fi
  fi

  echo "    ⚠ Java 25 not detected - installing Temurin 25 JRE"
  install -d /usr/share/keyrings
  
  if ! [ -f /usr/share/keyrings/adoptium.gpg ]; then
    curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
  fi
  
  if command -v apt-get &>/dev/null; then
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
      > /etc/apt/sources.list.d/adoptium.list
    apt-get update -y && apt-get install -y temurin-25-jre
  elif command -v yum &>/dev/null; then
    cat > /etc/yum.repos.d/adoptium.repo <<EOF
[Adoptium]
name=Adoptium
baseurl=https://packages.adoptium.net/artifactory/rpm/centos/\$releasever/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.adoptium.net/artifactory/api/gpg/key/public
EOF
    yum install -y temurin-25-jre
  else
    echo "    ✗ Cannot install Java automatically"
    exit 1
  fi
  echo "    ✓ Java 25 installed"
}

resolve_java_25() {
  local java_bin=""
  local candidate=""

  if command -v update-alternatives &>/dev/null; then
    while read -r candidate; do
      if [ -x "$candidate" ]; then
        local ver
        ver=$($candidate -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
        if [ "${ver:-0}" -eq 25 ]; then
          java_bin="$candidate"
          break
        fi
      fi
    done < <(update-alternatives --list java 2>/dev/null || true)
  fi

  if [ -z "$java_bin" ] && [ -d "/usr/lib/jvm" ]; then
    while read -r candidate; do
      if [ -x "$candidate" ]; then
        local ver
        ver=$($candidate -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
        if [ "${ver:-0}" -eq 25 ]; then
          java_bin="$candidate"
          break
        fi
      fi
    done < <(find /usr/lib/jvm -maxdepth 3 -type f -path "*/bin/java" 2>/dev/null | sort)
  fi

  if [ -z "$java_bin" ]; then
    echo "    ✗ Java 25 binary not found"
    echo "      Install Temurin 25 and ensure it is available"
    exit 1
  fi

  echo "$java_bin"
}

echo "[*] Hytale Server Installer"
echo ""

# Step 1: Create dedicated user and group
echo "[1] Setting up dedicated user: $HYTALE_USER"
mkdir -p "$INSTALL_DIR"
if ! id "$HYTALE_USER" &>/dev/null; then
  groupadd -r "$HYTALE_GROUP" || true
  useradd -r -g "$HYTALE_GROUP" -d "$INSTALL_DIR" -s /bin/false \
    -c "Hytale Server" "$HYTALE_USER" || true
  echo "    ✓ Created user $HYTALE_USER"
else
  echo "    ✓ User $HYTALE_USER already exists"
fi

# Step 2: Create directory structure with secure permissions
echo "[2] Setting up directories with secure permissions"
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/AppFiles"
mkdir -p "$INSTALL_DIR/AppFiles/Server"
mkdir -p "$INSTALL_DIR/logs"
touch "$INSTALL_DIR/logs/latest.log"

# Restrictive permissions: hytale user can read/write, others cannot
chmod 750 "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/logs" # Allow reads for debugging
chown -R "$HYTALE_USER:$HYTALE_GROUP" "$INSTALL_DIR"

echo "    ✓ Directories created"

# Step 3: Check/install Java 25
echo "[3] Checking Java runtime"
ensure_java
JAVA_BIN=$(resolve_java_25)
JAVA_VERSION=$($JAVA_BIN -version 2>&1 | head -1)
echo "    ✓ Using: $JAVA_VERSION"

# Step 4: Download Hytale downloader
echo "[4] Downloading Hytale downloader"
if ! command -v unzip &>/dev/null; then
  if command -v apt-get &>/dev/null; then
    apt-get install -y unzip
  elif command -v yum &>/dev/null; then
    yum install -y unzip
  fi
fi

DOWNLOADER_URL="https://downloader.hytale.com/hytale-downloader.zip"
curl -fL -o "$INSTALL_DIR/AppFiles/hytale-downloader.zip" "$DOWNLOADER_URL" || {
  echo "    ✗ Failed to download Hytale downloader"
  exit 1
}
unzip -o "$INSTALL_DIR/AppFiles/hytale-downloader.zip" -d "$INSTALL_DIR/AppFiles/" || {
  echo "    ✗ Failed to extract Hytale downloader"
  exit 1
}
chmod +x "$INSTALL_DIR/AppFiles/hytale-downloader-linux-amd64"
echo "    ✓ Downloaded Hytale downloader"

# Step 5: Download game files (requires authentication)
echo "[5] Downloading Hytale server files"
echo "    ⚠ You may be prompted to authenticate in your web browser"
cd "$INSTALL_DIR/AppFiles/"
sudo -u "$HYTALE_USER" ./hytale-downloader-linux-amd64 -print-version
cd -
chown -R "$HYTALE_USER:$HYTALE_GROUP" "$INSTALL_DIR/AppFiles/"

# Validate server files were downloaded
if [ ! -f "$INSTALL_DIR/AppFiles/Server/HytaleServer.jar" ]; then
  echo "    ✗ Hytale server JAR not found"
  echo "      Expected: $INSTALL_DIR/AppFiles/Server/HytaleServer.jar"
  echo "      Ensure you completed authentication for the downloader"
  exit 1
fi

echo "    ✓ Downloaded Hytale server files"

# Step 6: Create systemd unit file
echo "[6] Creating systemd service unit"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
SOCKET_UNIT="/etc/systemd/system/${SERVICE_NAME}.socket"
RUNTIME_SOCKET="/run/${SERVICE_NAME}.socket"
cat > "$SYSTEMD_UNIT" << 'EOF'
[Unit]
Description=Hytale Dedicated Server
Documentation=https://hytale.com
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hytale-srv
Group=hytale-srv

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
MemoryLimit=18G
CPUQuota=400%
TasksMax=1024
LimitNOFILE=65536

# Working directory and startup
WorkingDirectory={{INSTALL_DIR}}/AppFiles
ExecStart={{JAVA_BIN}} -server -Xms{{HEAP_MB}}M -Xmx{{HEAP_MB}}M -XX:MaxMetaspaceSize=512M -XX:+UnlockExperimentalVMOptions -XX:+UseShenandoahGC -XX:ShenandoahGCHeuristics=compact -XX:ShenandoahUncommitDelay=30000 -XX:ShenandoahAllocationThreshold=15 -XX:ShenandoahGuaranteedGCInterval=30000 -XX:+PerfDisableSharedMem -XX:+DisableExplicitGC -XX:+ParallelRefProcEnabled -XX:ParallelGCThreads=4 -XX:ConcGCThreads=2 -XX:+AlwaysPreTouch -jar {{INSTALL_DIR}}/AppFiles/Server/HytaleServer.jar --assets {{INSTALL_DIR}}/AppFiles/Assets.zip --accept-early-plugins

# Graceful shutdown
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=60

# Restart policy
Restart=on-failure
RestartSec=1800

[Install]
WantedBy=multi-user.target
EOF

# Create systemd socket unit for command execution
cat > "$SOCKET_UNIT" << 'EOF'
[Unit]
Description=Hytale Server Console Socket
Documentation=https://hytale.com
BindsTo={{SERVICE_NAME}}.service

[Socket]
ListenFIFO={{RUNTIME_SOCKET}}
Service={{SERVICE_NAME}}.service
RemoveOnStop=true
SocketMode=0660
SocketUser=hytale-srv
SocketGroup=hytale-srv

[Install]
WantedBy=sockets.target
EOF

# Replace template variables
sed -i "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" "$SYSTEMD_UNIT"
sed -i "s|{{HEAP_MB}}|${HEAP_MB:-4096}|g" "$SYSTEMD_UNIT"
sed -i "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" "$SYSTEMD_UNIT"
sed -i "s|{{JAVA_BIN}}|$JAVA_BIN|g" "$SYSTEMD_UNIT"
sed -i "s|{{RUNTIME_SOCKET}}|$RUNTIME_SOCKET|g" "$SOCKET_UNIT"
sed -i "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" "$SOCKET_UNIT"
sed -i "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" "$SOCKET_UNIT"

echo "    ✓ Created $SYSTEMD_UNIT"
echo "    ✓ Created $SOCKET_UNIT"

# Step 7: Create server configuration file
echo "[7] Creating server configuration template"
cat > "$INSTALL_DIR/AppFiles/Server/config.json" << 'EOF'
{
  "ServerName": "{{SERVER_NAME}}",
  "MOTD": "{{SERVER_MOTD}}",
  "Password": "",
  "MaxPlayers": {{MAX_PLAYERS}},
  "MaxViewRadius": 32,
  "Defaults": {
    "World": "default",
    "GameMode": "Adventure"
  }
}
EOF

# Replace server.properties template variables with defaults if not set
sed -i "s|{{SERVER_NAME}}|${SERVER_NAME:-Hytale Server}|g" "$INSTALL_DIR/AppFiles/Server/config.json"
sed -i "s|{{SERVER_MOTD}}|${SERVER_MOTD:-}|g" "$INSTALL_DIR/AppFiles/Server/config.json"
sed -i "s|{{MAX_PLAYERS}}|${MAX_PLAYERS:-100}|g" "$INSTALL_DIR/AppFiles/Server/config.json"

chown "$HYTALE_USER:$HYTALE_GROUP" "$INSTALL_DIR/AppFiles/Server/config.json"
chmod 640 "$INSTALL_DIR/AppFiles/Server/config.json"
echo "    ✓ Created server configuration template"

# Step 8: Reload systemd and show status
echo "[8] Finalizing systemd configuration"
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service 2>/dev/null || true
systemctl enable ${SERVICE_NAME}.socket 2>/dev/null || true
# Start the socket (required before service can start)
systemctl start ${SERVICE_NAME}.socket 2>/dev/null || true
echo "    ✓ Systemd configured"
echo "    ✓ Socket enabled for console command execution"

echo ""
echo "✅ Installation Complete!"
echo ""
echo "📋 Next Steps:"
echo "   1. Edit $INSTALL_DIR/AppFiles/Server/config.json with your settings"
echo "   2. Start: sudo systemctl start ${SERVICE_NAME}"
echo "   3. Check logs: sudo journalctl -u ${SERVICE_NAME} -f"
echo "   4. Send commands via socket (requires server to be running)"
echo ""
echo "🔒 Security Notes:"
echo "   • Server runs as non-root user: $HYTALE_USER"
echo "   • Protected home directory: ProtectHome=yes"
echo "   • No privilege escalation: NoNewPrivileges=true"
echo "   • Memory limited to 18GB (adjust HEAP_MB in unit file)"
echo "   • File permissions: 750 (owner+group only)"
echo "   • Socket mode: 0660 (hytale user + group only)"
echo "   • Consider firewall rules: sudo ufw allow 5520/udp"
echo ""
echo "📡 Console Socket:"
echo "   • Location: ${RUNTIME_SOCKET}"
echo "   • Send commands: echo 'help' | sudo nc -U ${RUNTIME_SOCKET}"
echo "   • Or use frontend console for integrated command execution"
echo ""
echo "⚠️ Important: Hytale requires Java 25 specifically!"
echo ""
