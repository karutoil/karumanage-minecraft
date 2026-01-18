#!/bin/bash
set -euo pipefail

# Minecraft Server Installer
# Security-focused installation for Paper Minecraft servers

PAPER_JAR_URL="${1:-https://fill-data.papermc.io/v1/objects/b727f13945dd442cd2bc1de6c64680e8630e7f54ba259aac7687e9c7c3cc18a3/paper-1.21.11-97.jar}"
PAPER_JAR_CHECKSUM="${2:-}" # Optional checksum verification
INSTALL_DIR="${INSTALL_DIR:-/opt/minecraft}"
MINECRAFT_USER="minecraft-srv"
MINECRAFT_GROUP="minecraft-srv"

ensure_java() {
  if command -v java &>/dev/null; then
    local ver
    ver=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
    if [ "${ver:-0}" -ge 21 ]; then
      echo "    ✓ Found Java ${ver}"
      return
    fi
  fi

  echo "    ⚠ Java <21 detected - installing Temurin 21 JRE"
  if command -v apt-get &>/dev/null; then
    # Add Adoptium repo for Temurin 21
    install -d /usr/share/keyrings
    if ! [ -f /usr/share/keyrings/adoptium.gpg ]; then
      curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
    fi
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
      > /etc/apt/sources.list.d/adoptium.list
    apt-get update -y && apt-get install -y temurin-21-jre || apt-get install -y openjdk-21-jre-headless || apt-get install -y openjdk-17-jre-headless
  elif command -v yum &>/dev/null; then
    yum install -y java-21-openjdk-headless || yum install -y java-17-openjdk-headless
  else
    echo "    ✗ Cannot install Java automatically"
    exit 1
  fi
  echo "    ✓ Java installed: $(java -version 2>&1 | head -1)"
}

echo "[*] Minecraft Server Installer"
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
touch "$INSTALL_DIR/logs/latest.log"

# Restrictive permissions: minecraft user can read/write, others cannot
chmod 750 "$INSTALL_DIR"
chmod 755 "$INSTALL_DIR/logs" # Allow reads for debugging
chown -R "$MINECRAFT_USER:$MINECRAFT_GROUP" "$INSTALL_DIR"

echo "    ✓ Directories created"

# Step 3: Download Paper JAR
echo "[3] Downloading Paper Minecraft JAR"
JAR_FILE="$INSTALL_DIR/paper-server.jar"
curl -fL -o "$JAR_FILE" "$PAPER_JAR_URL" || {
  echo "    ✗ Failed to download jar"
  exit 1
}
echo "    ✓ Downloaded $(ls -lh "$JAR_FILE" | awk '{print $5}')"

# Step 4: Verify checksum if provided
if [ -n "$PAPER_JAR_CHECKSUM" ]; then
  echo "[4] Verifying JAR checksum"
  ACTUAL_CHECKSUM=$(sha256sum "$JAR_FILE" | awk '{print $1}')
  if [ "$ACTUAL_CHECKSUM" != "$PAPER_JAR_CHECKSUM" ]; then
    echo "    ✗ Checksum mismatch!"
    echo "      Expected: $PAPER_JAR_CHECKSUM"
    echo "      Got: $ACTUAL_CHECKSUM"
    rm -f "$JAR_FILE"
    exit 1
  fi
  echo "    ✓ Checksum verified"
fi

# Step 5: Check/install Java 21+
echo "[5] Checking Java runtime"
ensure_java
JAVA_VERSION=$(java -version 2>&1 | head -1)
echo "    ✓ Using: $JAVA_VERSION"

# Step 6: Create systemd unit file
echo "[6] Creating systemd service unit"
SYSTEMD_UNIT="/etc/systemd/system/minecraft-server.service"
SOCKET_UNIT="/etc/systemd/system/minecraft-server.socket"
cat > "$SYSTEMD_UNIT" << 'EOF'
[Unit]
Description=Minecraft Paper Server
Documentation=https://papermc.io
After=network-online.target minecraft-server.socket
Wants=network-online.target

[Service]
Type=simple
User=minecraft-srv
Group=minecraft-srv

# Security hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths={{INSTALL_DIR}} {{INSTALL_DIR}}/worlds {{INSTALL_DIR}}/logs /run/minecraft-server.sock

# Resource limits
MemoryLimit=4G
CPUQuota=200%
TasksMax=512
LimitNOFILE=65536

# Working directory and startup
WorkingDirectory={{INSTALL_DIR}}
ExecStart=/usr/bin/java -Xmx{{HEAP_MB}}M -Xms{{HEAP_MB}}M -XX:+UseG1GC -XX:MaxGCPauseMillis=200 -jar paper-server.jar nogui

# Graceful shutdown (Paper handles SIGTERM)
KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=30

# Logging
StandardOutput=journal
StandardError=journal
SyslogIdentifier=minecraft

# Restart policy
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# Create systemd socket unit for command execution
cat > "$SOCKET_UNIT" << 'EOF'
[Unit]
Description=Minecraft Server Console Socket
Documentation=https://papermc.io
Before=minecraft-server.service

[Socket]
ListenStream=/run/minecraft-server.sock
SocketMode=0660
SocketUser=minecraft-srv
SocketGroup=minecraft-srv
Accept=false

[Install]
WantedBy=sockets.target
EOF

# Replace template variables
sed -i "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" "$SYSTEMD_UNIT"
sed -i "s|{{HEAP_MB}}|2048|g" "$SYSTEMD_UNIT"  # Default 2GB, adjust as needed

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

# Step 8: Create server.properties template
echo "[8] Creating server.properties template"
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

chown "$MINECRAFT_USER:$MINECRAFT_GROUP" "$INSTALL_DIR/server.properties"
chmod 640 "$INSTALL_DIR/server.properties"
echo "    ✓ Created server.properties template"

# Step 9: Set JAR permissions
chown "$MINECRAFT_USER:$MINECRAFT_GROUP" "$JAR_FILE"
chmod 640 "$JAR_FILE"
echo "    ✓ Set JAR permissions"

# Step 10: Reload systemd and show status
echo "[10] Finalizing systemd configuration"
systemctl daemon-reload
systemctl enable minecraft-server.service 2>/dev/null || true
systemctl enable minecraft-server.socket 2>/dev/null || true
echo "    ✓ Systemd configured"
echo "    ✓ Socket enabled for console command execution"

echo ""
echo "✅ Installation Complete!"
echo ""
echo "📋 Next Steps:"
echo "   1. Edit $INSTALL_DIR/server.properties with your settings"
echo "   2. Start: sudo systemctl start minecraft-server"
echo "   3. Check logs: sudo journalctl -u minecraft-server -f"
echo "   4. Send commands: echo 'command' | nc -U /run/minecraft-server.sock"
echo ""
echo "🔒 Security Notes:"
echo "   • Server runs as non-root user: $MINECRAFT_USER"
echo "   • Systemd uses ProtectSystem=strict, ProtectHome=yes"
echo "   • Memory limited to 4GB (adjust HEAP_MB in unit file)"
echo "   • File permissions: 750 (owner+group only)"
echo "   • Socket mode: 0660 (minecraft user + group only)"
echo "   • Consider firewall rules: sudo ufw allow 25565/tcp"
echo ""
echo "📡 Console Socket:"
echo "   • Location: /run/minecraft-server.sock"
echo "   • Send commands: echo 'help' | sudo nc -U /run/minecraft-server.sock"
echo "   • Or use frontend console for integrated command execution"
echo ""
