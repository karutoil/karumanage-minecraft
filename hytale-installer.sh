#!/bin/bash
set -euo pipefail

# Hytale Server Installer
# Secure installation for Hytale servers (Java 25 only)
#
# Required environment variables:
#   INSTANCE_ID - UUID of the instance (e.g., 16652474-c4a3-4b9a-8fb4-b1c7a5bb1681)
#
# Usage: INSTANCE_ID=<uuid> ./hytale-installer.sh
#
# Optional environment variables:
#   INSTALL_DIR - Installation directory (default: /opt/hytale-${INSTANCE_ID})
#   SERVER_PORT - Server port (default: 5520)
#   PATCHLINE - release channel (default: release)
#   AUTOMATIC_UPDATE - 1/0 (default: 1)
#   SERVER_MEMORY - Max Java heap in MB (default: 8192)
#   MEMORY_OVERHEAD - MB reserved for system (default: 0)
#   JVM_ARGS - Extra JVM args (default: empty)
#   AUTH_MODE - authenticated|offline (default: authenticated)
#   LEVERAGE_AHEAD_OF_TIME_CACHE - 1/0 (default: 1)
#   DISABLE_SENTRY - 1/0 (default: 1)
#   ALLOW_OP - 1/0 (default: 1)
#   ENABLE_BACKUPS - 1/0 (default: 0)
#   BACKUP_FREQUENCY - minutes (default: 30)
#   MAXIMUM_BACKUPS - count (default: 5)

INSTANCE_ID="${INSTANCE_ID:-default}"
INSTALL_DIR="${INSTALL_DIR:-/opt/hytale-${INSTANCE_ID}}"
SERVICE_NAME="hytale-server-${INSTANCE_ID}"
HYTALE_USER="hytale-srv"
HYTALE_GROUP="hytale-srv"
DEFAULTS_FILE="/etc/default/${SERVICE_NAME}"

DOWNLOAD_URL="https://downloader.hytale.com/hytale-downloader.zip"
DOWNLOAD_FILE="hytale-downloader.zip"

ensure_java25() {
  if command -v java &>/dev/null; then
    local ver
    ver=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
    if [ "${ver:-0}" -eq 25 ]; then
      echo "    ✓ Found Java ${ver}"
      return
    fi
  fi

  echo "    ⚠ Java 25 not detected - installing Temurin 25 JRE"
  if command -v apt-get &>/dev/null; then
    install -d /usr/share/keyrings
    if ! [ -f /usr/share/keyrings/adoptium.gpg ]; then
      curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg
    fi
    echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" \
      > /etc/apt/sources.list.d/adoptium.list
    apt-get update -y
    apt-get install -y temurin-25-jre
  elif command -v yum &>/dev/null; then
    yum install -y java-25-openjdk-headless
  else
    echo "    ✗ Cannot install Java automatically"
    exit 1
  fi

  if ! command -v java &>/dev/null; then
    echo "    ✗ Java 25 install failed"
    exit 1
  fi

  local ver
  ver=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
  if [ "${ver:-0}" -ne 25 ]; then
    echo "    ✗ Java 25 required, found ${ver:-unknown}"
    exit 1
  fi

  echo "    ✓ Java installed: $(java -version 2>&1 | head -1)"
}

install_deps() {
  if command -v apt-get &>/dev/null; then
    apt-get update -y
    apt-get install -y curl unzip jq

    if [ "$(uname -m)" = "aarch64" ]; then
      apt-get install -y qemu-user-static
      dpkg --add-architecture amd64 || true
      apt-get update -y
      apt-get install -y libc6:amd64 || true
    fi
  elif command -v yum &>/dev/null; then
    yum install -y curl unzip jq
  else
    echo "    ✗ Cannot install dependencies automatically"
    exit 1
  fi
}

create_hytale_user() {
  if ! id "$HYTALE_USER" &>/dev/null; then
    groupadd -r "$HYTALE_GROUP" || true
    useradd -r -g "$HYTALE_GROUP" -d "$INSTALL_DIR" -s /bin/false \
      -c "Hytale Server" "$HYTALE_USER" || true
    echo "    ✓ Created user $HYTALE_USER"
  else
    echo "    ✓ User $HYTALE_USER already exists"
  fi
}

setup_directories() {
  mkdir -p "$INSTALL_DIR"
  mkdir -p "$INSTALL_DIR/logs"
  mkdir -p "$INSTALL_DIR/backup"
  mkdir -p "$INSTALL_DIR/lib"
  chmod 750 "$INSTALL_DIR"
  chmod 755 "$INSTALL_DIR/logs"
  chmod 755 "$INSTALL_DIR/backup"
  chown -R "$HYTALE_USER:$HYTALE_GROUP" "$INSTALL_DIR"
}

install_downloader() {
  echo "    ✓ Downloading Hytale downloader"
  curl -fL -o "$INSTALL_DIR/$DOWNLOAD_FILE" "$DOWNLOAD_URL"
  unzip -o "$INSTALL_DIR/$DOWNLOAD_FILE" -d "$INSTALL_DIR" >/dev/null
  rm -f "$INSTALL_DIR/$DOWNLOAD_FILE" "$INSTALL_DIR/QUICKSTART.md" "$INSTALL_DIR/hytale-downloader-windows-amd64.exe"
  chmod +x "$INSTALL_DIR/hytale-downloader-linux-amd64" || true

  if [ "$(uname -m)" = "aarch64" ]; then
    cp /usr/bin/qemu-x86_64-static "$INSTALL_DIR/qemu-x86_64-static"
    cat > "$INSTALL_DIR/hytale-downloader-linux-arm64" << 'EOF'
#!/bin/bash
set -e

REAL_BIN="/opt/hytale-INSTANCE/hytale-downloader-linux-amd64"
QEMU_LOCAL="/opt/hytale-INSTANCE/qemu-x86_64-static"

if [ -x "$QEMU_LOCAL" ]; then
  exec "$QEMU_LOCAL" "$REAL_BIN" "$@"
else
  exec /usr/bin/qemu-x86_64-static "$REAL_BIN" "$@"
fi
EOF
    chmod +x "$INSTALL_DIR/hytale-downloader-linux-arm64"
  fi
}

write_lib_scripts() {
  cat > "$INSTALL_DIR/lib/utilities.sh" << 'EOF'
# Setup colors
RED="" GREEN="" YELLOW="" BLUE="" MAGENTA="" CYAN="" RESET=""
if [ -t 1 ] || { [ -n "$TERM" ] && [ "$TERM" != "dumb" ]; }; then
    # Helper to get color code (tput or ANSI fallback)
    if command -v tput >/dev/null 2>&1 && tput setaf 1 >/dev/null 2>&1; then
        _c() { tput setaf "$1"; }
        _r() { tput sgr0; }
    else
        _c() { printf '\033[0;3%dm' "$1"; }
        _r() { printf '\033[0m'; }
    fi

    RED=$(_c 1) GREEN=$(_c 2) YELLOW=$(_c 3)
    BLUE=$(_c 4) MAGENTA=$(_c 5) CYAN=$(_c 6)
    RESET=$(_r)
    unset -f _c _r
fi

#Function to print colored text
printc() {
    local text="$1"

    # Replace tags with color codes (or empty string if not supported)
    text="${text//\{RED\}/$RED}"
    text="${text//\{GREEN\}/$GREEN}"
    text="${text//\{YELLOW\}/$YELLOW}"
    text="${text//\{BLUE\}/$BLUE}"
    text="${text//\{MAGENTA\}/$MAGENTA}"
    text="${text//\{CYAN\}/$CYAN}"
    text="${text//\{RESET\}/$RESET}"
    printf "%b\n" "$text"
}

# Logger function to print messages with different colors based on level
logger() {
    local level="$1"
    local message="$2"

    case "${level^^}" in
        "INFO")    printc "{BLUE}ℹ $message{RESET}" ;;
        "WARN")    printc "{YELLOW}⚠ $message{RESET}" ;;
        "ERROR")   printc "{RED}⨯ $message{RESET}" ;;
        "SUCCESS") printc "{GREEN}✓ $message{RESET}" ;;
        *)         printc "$message" ;;
    esac
}

# Function to extract downloaded server files
extract_server_files() {
    logger info "Extracting server files..."
    SERVER_ZIP="server.zip"

    if [ -f "$SERVER_ZIP" ]; then
        logger success "Found server archive: $SERVER_ZIP"

        # Extract to current directory
        unzip -o "$SERVER_ZIP"

        if [ $? -ne 0 ]; then
            logger error "Failed to extract $SERVER_ZIP"
            exit 1
        fi

        logger success "Extraction completed successfully."

        # Move contents from Server folder to current directory
        if [ -d "Server" ]; then
            logger info "Moving server files from Server directory..."
            cp -rf Server/* .
            rm -rf ./Server
            logger success "Server files moved to root directory."
        fi

        # Clean up the zip file
        logger info "Cleaning up archive file..."
        rm "$SERVER_ZIP"
        logger success "Archive removed."
    else
        logger error "Server archive not found at $SERVER_ZIP"
        exit 1
    fi
}
EOF

  cat > "$INSTALL_DIR/lib/system.sh" << 'EOF'
#!/bin/bash

detect_architecture() {
    local ARCH=$(uname -m)
    logger info "Platform: $ARCH"

    case "$ARCH" in
        x86_64)
            DOWNLOADER="./hytale-downloader-linux-amd64"
            ;;
        aarch64|arm64)
            DOWNLOADER="./hytale-downloader-linux-arm64"
            ;;
        *)
            logger error "Unsupported architecture: $ARCH"
            logger info "Supported architectures: x86_64 (amd64), aarch64/arm64"
            exit 1
            ;;
    esac
}

setup_environment() {
    export TZ=${TZ:-UTC}
    export INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
    cd "$BASE_DIR" || exit 1
}

setup_backup_directory() {
    if [ ! -d "backup" ]; then
        logger info "Backup directory does not exist. Creating it..."
        mkdir -p backup
        if [ $? -ne 0 ]; then
            logger error "Failed to create backup directory: /backup"
            exit 1
        fi
    fi
    chmod -R 755 backup
}

enforce_permissions() {
    if [ "${ENFORCE_PERMISSIONS:-0}" = "1" ]; then
        logger warn "Enforcing permissions... This might take a while. Please be patient."
        find . -type d -exec chmod 755 {} \;
        find . -type f \
            ! -name "hytale-downloader-linux-amd64" \
            ! -name "hytale-downloader-linux-arm64" \
            ! -name "start.sh" \
            -exec chmod 644 {} \;
        logger success "Permissions enforced (files: 644, folders: 755)"
    fi
}
EOF

  cat > "$INSTALL_DIR/lib/downloader.sh" << 'EOF'
#!/bin/bash

ensure_downloader() {
    if [ ! -f "$DOWNLOADER" ]; then
        logger error "Hytale downloader not found!"
        logger error "Please run the installation script first."
        exit 1
    fi

    if [ ! -x "$DOWNLOADER" ]; then
        logger info "Setting executable permissions for downloader..."
        chmod +x "$DOWNLOADER"
    fi
}

run_update_process() {
    local INITIAL_SETUP=0

    if [ ! -f "$DOWNLOAD_CRED_FILE" ]; then
        INITIAL_SETUP=1
        logger warn "Credentials file not found, running initial setup..."
        logger info "Downloading server files..."

        $DOWNLOADER -check-update

        echo " "
        printc "{MAGENTA}╔══════════════════════════════════════════════════════════════════════════════════════╗"
        printc "{MAGENTA}║  {BLUE}NOTE: You must have purchased Hytale on the account you are using to authenticate.  {MAGENTA}║"
        printc "{MAGENTA}╚══════════════════════════════════════════════════════════════════════════════════════╝"
        echo " "

        if ! $DOWNLOADER -patchline $PATCHLINE -download-path server.zip; then
            echo ""
            logger error "Failed to download Hytale server files."
            logger warn "Removing invalid credential file..."
            rm -f $DOWNLOAD_CRED_FILE
            exit 1
        fi

        local DOWNLOADER_VERSION=$($DOWNLOADER -print-version -skip-update-check 2>&1)
        if [ $? -eq 0 ] && [ -n "$DOWNLOADER_VERSION" ]; then
            echo "$DOWNLOADER_VERSION" > $VERSION_FILE
            logger success "Saved version info!"
        fi

        extract_server_files
    fi

    if [ "${AUTOMATIC_UPDATE:-1}" = "1" ] && [ "$INITIAL_SETUP" = "0" ]; then
        logger info "Checking for updates..."

        local LOCAL_VERSION=""
        if [ -f "$VERSION_FILE" ]; then
            LOCAL_VERSION=$(cat $VERSION_FILE)
        else
            logger warn "Version file not found, forcing update"
        fi

        local DOWNLOADER_VERSION=$($DOWNLOADER -print-version -skip-update-check 2>&1)

        if [ $? -ne 0 ] || [ -z "$DOWNLOADER_VERSION" ]; then
            logger error "Failed to get downloader version."
            exit 1
        else
            if [ -n "$LOCAL_VERSION" ]; then
                logger info "Local version: $LOCAL_VERSION"
            fi
            logger info "Downloader version: $DOWNLOADER_VERSION"

            if [ "$LOCAL_VERSION" != "$DOWNLOADER_VERSION" ]; then
                logger warn "Version mismatch, running update..."
                $DOWNLOADER -check-update
                $DOWNLOADER -patchline $PATCHLINE -download-path server.zip
                echo "$DOWNLOADER_VERSION" > $VERSION_FILE
                logger success "Saved version info!"
                extract_server_files
                logger success "Server has been updated successfully!"
            else
                logger info "Versions match, skipping update"
            fi
        fi
    fi
}

validate_server_files() {
    if [ ! -f "HytaleServer.jar" ]; then
        logger error "HytaleServer.jar not found!"
        logger error "Server files were not downloaded correctly."
        exit 1
    fi
}
EOF

  cat > "$INSTALL_DIR/lib/authentication.sh" << 'EOF'
# Function to check if cached tokens exist
check_cached_tokens() {
    if [ -f "$AUTH_CACHE_FILE" ]; then
        if ! command -v jq &> /dev/null; then
            logger warn "jq not found, cannot use cached tokens"
            return 1
        fi

        if ! jq empty "$AUTH_CACHE_FILE" 2>/dev/null; then
            logger warn "Invalid cached token file, removing..."
            rm "$AUTH_CACHE_FILE"
            return 1
        fi

        REFRESH_TOKEN_EXISTS=$(jq -r 'has("refresh_token")' "$AUTH_CACHE_FILE")
        PROFILE_UUID_EXISTS=$(jq -r 'has("profile_uuid")' "$AUTH_CACHE_FILE")

        if [ "$REFRESH_TOKEN_EXISTS" != "true" ] || [ "$PROFILE_UUID_EXISTS" != "true" ]; then
            logger warn "Cached token file missing required keys, removing..."
            rm "$AUTH_CACHE_FILE"
            return 1
        fi

        logger success "Found cached authentication tokens"
        return 0
    fi
    return 1
}

load_cached_tokens() {
    REFRESH_TOKEN=$(jq -r '.refresh_token' "$AUTH_CACHE_FILE")
    PROFILE_UUID=$(jq -r '.profile_uuid' "$AUTH_CACHE_FILE")

    if [ -z "$REFRESH_TOKEN" ] || [ "$REFRESH_TOKEN" = "null" ] || \
       [ -z "$PROFILE_UUID" ] || [ "$PROFILE_UUID" = "null" ]; then
        logger error "Incomplete cached tokens, re-authenticating..."
        rm "$AUTH_CACHE_FILE"
        return 1
    fi

    logger success "Loaded cached refresh token + profile UUID"
    return 0
}

refresh_access_token() {
    logger info "Refreshing access token..."

    TOKEN_RESPONSE=$(curl -s -X POST "https://oauth.accounts.hytale.com/oauth2/token" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "client_id=hytale-server" \
      -d "grant_type=refresh_token" \
      -d "refresh_token=$REFRESH_TOKEN")

    ERROR=$(echo "$TOKEN_RESPONSE" | jq -r '.error // empty')
    if [ -n "$ERROR" ]; then
        logger error "Failed to refresh access token: $ERROR"
        return 1
    fi

    ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
    NEW_REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.refresh_token // empty')

    if [ -z "$ACCESS_TOKEN" ] || [ "$ACCESS_TOKEN" = "null" ]; then
        logger error "No access token in refresh response"
        return 1
    fi

    if [ -n "$NEW_REFRESH_TOKEN" ] && [ "$NEW_REFRESH_TOKEN" != "null" ]; then
        REFRESH_TOKEN="$NEW_REFRESH_TOKEN"
    fi

    logger success "Access token refreshed"
    return 0
}

create_game_session() {
    logger info "Creating game server session..."

    SESSION_RESPONSE=$(curl -s -X POST "https://sessions.hytale.com/game-session/new" \
      -H "Authorization: Bearer $ACCESS_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"uuid\": \"$PROFILE_UUID\"}")

    if ! echo "$SESSION_RESPONSE" | jq empty 2>/dev/null; then
        logger error "Invalid JSON response from game session creation"
        logger info "Response: $SESSION_RESPONSE"
        return 1
    fi

    SESSION_TOKEN=$(echo "$SESSION_RESPONSE" | jq -r '.sessionToken')
    IDENTITY_TOKEN=$(echo "$SESSION_RESPONSE" | jq -r '.identityToken')

    if [ -z "$SESSION_TOKEN" ] || [ "$SESSION_TOKEN" = "null" ]; then
        logger error "Failed to create game server session"
        logger info "Response: $SESSION_RESPONSE"
        return 1
    fi

    logger success "Game server session created successfully!"
    return 0
}

save_auth_tokens() {
    if [ ! -f "$AUTH_CACHE_FILE" ]; then
        logger info "Creating auth cache file..."
        touch $AUTH_CACHE_FILE
    fi

    cat > "$AUTH_CACHE_FILE" << EOF
{
  "refresh_token": "$REFRESH_TOKEN",
  "profile_uuid": "$PROFILE_UUID",
  "timestamp": $(date +%s)
}
EOF
    logger info "Refresh token cached for future use"
}

perform_authentication() {
    logger info "Obtaining authentication tokens..."

    AUTH_RESPONSE=$(curl -s -X POST "https://oauth.accounts.hytale.com/oauth2/device/auth" \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -d "client_id=hytale-server" \
      -d "scope=openid offline auth:server")

    DEVICE_CODE=$(echo "$AUTH_RESPONSE" | jq -r '.device_code')
    VERIFICATION_URI=$(echo "$AUTH_RESPONSE" | jq -r '.verification_uri_complete')
    POLL_INTERVAL=$(echo "$AUTH_RESPONSE" | jq -r '.interval')

    echo " "
    printc "{MAGENTA}╔═════════════════════════════════════════════════════════════════════════════╗"
    printc "{MAGENTA}║                       {BLUE}HYTALE SERVER AUTHENTICATION REQUIRED                 {MAGENTA}║"
    printc "{MAGENTA}╠═════════════════════════════════════════════════════════════════════════════╣"
    printc "{MAGENTA}║                                                                             ║"
    printc "{MAGENTA}║  {CYAN}Please authenticate the server by visiting the following URL:              {MAGENTA}║"
    printc "{MAGENTA}║                                                                             ║"
    printc "{MAGENTA}║  {YELLOW}$VERIFICATION_URI  {MAGENTA}║"
    printc "{MAGENTA}║                                                                             ║"
    printc "{MAGENTA}║  {CYAN}1. Click the link above or copy it to your browser                         {MAGENTA}║"
    printc "{MAGENTA}║  {CYAN}2. Sign in with your Hytale account                                        {MAGENTA}║"
    printc "{MAGENTA}║  {CYAN}3. Authorize the server                                                    {MAGENTA}║"
    printc "{MAGENTA}║                                                                             ║"
    printc "{MAGENTA}║  {CYAN}Waiting for authentication...                                              {MAGENTA}║"
    printc "{MAGENTA}║                                                                             ║"
    printc "{MAGENTA}╚═════════════════════════════════════════════════════════════════════════════╝"
    printc " "

    ACCESS_TOKEN=""
    while [ -z "$ACCESS_TOKEN" ]; do
        sleep $POLL_INTERVAL

        TOKEN_RESPONSE=$(curl -s -X POST "https://oauth.accounts.hytale.com/oauth2/token" \
          -H "Content-Type: application/x-www-form-urlencoded" \
          -d "client_id=hytale-server" \
          -d "grant_type=urn:ietf:params:oauth:grant-type:device_code" \
          -d "device_code=$DEVICE_CODE")

        ERROR=$(echo "$TOKEN_RESPONSE" | jq -r '.error // empty')

        if [ "$ERROR" = "authorization_pending" ]; then
            logger info "Still waiting for authentication..."
            continue
        elif [ -n "$ERROR" ]; then
            logger error "Authentication error: $ERROR"
            exit 1
        else
            ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token')
            REFRESH_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.refresh_token')
            echo ""
            logger success "Authentication successful!"
            echo ""
        fi
    done

    logger info "Fetching game profiles..."

    PROFILES_RESPONSE=$(curl -s -X GET "https://account-data.hytale.com/my-account/get-profiles" \
      -H "Authorization: Bearer $ACCESS_TOKEN")

    PROFILES_COUNT=$(echo "$PROFILES_RESPONSE" | jq '.profiles | length')

    if [ "$PROFILES_COUNT" -eq 0 ]; then
        logger error "No game profiles found. You need to purchase Hytale to run a server."
        exit 1
    fi

    if [ -n "$GAME_PROFILE" ]; then
        logger info "Looking for profile: $GAME_PROFILE"
        PROFILE_UUID=$(echo "$PROFILES_RESPONSE" | jq -r ".profiles[] | select(.username == \"$GAME_PROFILE\") | .uuid")

        if [ -z "$PROFILE_UUID" ] || [ "$PROFILE_UUID" = "null" ]; then
            logger error "Profile '$GAME_PROFILE' not found."
            logger info "Available profiles:"
            logger success "$PROFILES_RESPONSE" | jq -r '.profiles[] | "  - \(.username)"'
            exit 1
        fi

        logger success "Using profile: $GAME_PROFILE (UUID: $PROFILE_UUID)"
    else
        PROFILE_UUID=$(echo "$PROFILES_RESPONSE" | jq -r '.profiles[0].uuid')
        PROFILE_USERNAME=$(echo "$PROFILES_RESPONSE" | jq -r '.profiles[0].username')

        logger success "Using default profile: $PROFILE_USERNAME (UUID: $PROFILE_UUID)"
    fi

    echo ""

    save_auth_tokens

    if ! create_game_session; then
        exit 1
    fi
    echo ""
}
EOF
}

write_entrypoint() {
  cat > "$INSTALL_DIR/entrypoint.sh" << 'EOF'
#!/bin/bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"

source "$BASE_DIR/lib/utilities.sh"
source "$BASE_DIR/lib/authentication.sh"
source "$BASE_DIR/lib/system.sh"
source "$BASE_DIR/lib/downloader.sh"

DOWNLOAD_URL="https://downloader.hytale.com/hytale-downloader.zip"
DOWNLOAD_FILE="hytale-downloader.zip"
DOWNLOAD_CRED_FILE=".hytale-downloader-credentials.json"
AUTH_CACHE_FILE=".hytale-auth-tokens.json"
VERSION_FILE="version.txt"

PATCHLINE="${PATCHLINE:-release}"
AUTOMATIC_UPDATE="${AUTOMATIC_UPDATE:-1}"

ensure_java25_runtime() {
  if ! command -v java &>/dev/null; then
    logger error "Java 25 not installed"
    exit 1
  fi
  local ver
  ver=$(java -version 2>&1 | head -1 | sed -E 's/.*version "([0-9]+).*/\1/')
  if [ "${ver:-0}" -ne 25 ]; then
    logger error "Java 25 required, found ${ver:-unknown}"
    exit 1
  fi
}

install_downloader_if_missing() {
  if [ ! -f "$BASE_DIR/hytale-downloader-linux-amd64" ]; then
    logger info "Downloading Hytale downloader..."
    curl -fL -o "$BASE_DIR/$DOWNLOAD_FILE" "$DOWNLOAD_URL"
    unzip -o "$BASE_DIR/$DOWNLOAD_FILE" -d "$BASE_DIR" >/dev/null
    rm -f "$BASE_DIR/$DOWNLOAD_FILE" "$BASE_DIR/QUICKSTART.md" "$BASE_DIR/hytale-downloader-windows-amd64.exe"
    chmod +x "$BASE_DIR/hytale-downloader-linux-amd64" || true

    if [ "$(uname -m)" = "aarch64" ]; then
      if [ ! -f "$BASE_DIR/qemu-x86_64-static" ]; then
        logger error "qemu-x86_64-static missing; install qemu-user-static"
        exit 1
      fi
      cat > "$BASE_DIR/hytale-downloader-linux-arm64" << 'EOF_ARM'
#!/bin/bash
set -e

REAL_BIN="/opt/hytale-INSTANCE/hytale-downloader-linux-amd64"
QEMU_LOCAL="/opt/hytale-INSTANCE/qemu-x86_64-static"

if [ -x "$QEMU_LOCAL" ]; then
  exec "$QEMU_LOCAL" "$REAL_BIN" "$@"
else
  exec /usr/bin/qemu-x86_64-static "$REAL_BIN" "$@"
fi
EOF_ARM
      chmod +x "$BASE_DIR/hytale-downloader-linux-arm64"
    fi
  fi
}

ensure_java25_runtime
install_downloader_if_missing

# Initialize system
logger info "Initializing environment..."
detect_architecture
setup_environment

setup_backup_directory
ensure_downloader

# Create version file
if [ ! -f "$VERSION_FILE" ]; then
    logger info "Creating version check file..."
    touch $VERSION_FILE
fi

run_update_process
validate_server_files

# Authentication
if [ -n "${OVERRIDE_SESSION_TOKEN:-}" ] && [ -n "${OVERRIDE_IDENTITY_TOKEN:-}" ]; then
    logger info "Using provided session and identity tokens..."
    SESSION_TOKEN="$OVERRIDE_SESSION_TOKEN"
    IDENTITY_TOKEN="$OVERRIDE_IDENTITY_TOKEN"
else
    if [ -z "${USE_PERSISTENT_AUTHENTICATION:-}" ]; then
        USE_PERSISTENT_AUTHENTICATION="ENABLED"
    fi

    if [ "$USE_PERSISTENT_AUTHENTICATION" = "ENABLED" ]; then
        if check_cached_tokens && load_cached_tokens; then
            logger info "Using cached authentication..."
            if refresh_access_token; then
                save_auth_tokens
                if ! create_game_session; then
                    exit 1
                fi
            else
                logger info "Refresh token expired, re-authenticating..."
                rm -f "$AUTH_CACHE_FILE"
                perform_authentication
            fi
        else
            perform_authentication
        fi
    fi
fi

export SESSION_TOKEN
export IDENTITY_TOKEN

enforce_permissions

logger info "Starting Hytale server..."
cd "$BASE_DIR"
exec "$BASE_DIR/start.sh"
EOF

  chmod 755 "$INSTALL_DIR/entrypoint.sh"
}

write_start_script() {
  cat > "$INSTALL_DIR/start.sh" << 'EOF'
#!/bin/bash

# WARNING: DO NOT EDIT THIS FILE MANUALLY!
# This file is automatically managed by the Hytale installer.

JAVA_CMD="java"

if [ "${LEVERAGE_AHEAD_OF_TIME_CACHE:-1}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} -XX:AOTCache=HytaleServer.aot"
fi

MEMORY_OVERHEAD=${MEMORY_OVERHEAD:-0}
if [ -n "${SERVER_MEMORY:-}" ] && [ "${SERVER_MEMORY}" != "0" ]; then
    if [ "${SERVER_MEMORY}" -gt "${MEMORY_OVERHEAD}" ] 2>/dev/null; then
        JAVA_MEMORY=$((SERVER_MEMORY - MEMORY_OVERHEAD))
    else
        JAVA_MEMORY=${SERVER_MEMORY}
    fi
    JAVA_CMD="${JAVA_CMD} -Xmx${JAVA_MEMORY}M"
fi

if [ -n "${JVM_ARGS:-}" ]; then
    JAVA_CMD="${JAVA_CMD} ${JVM_ARGS}"
fi

JAVA_CMD="${JAVA_CMD} -jar HytaleServer.jar"

if [ -n "${ASSET_PACK:-}" ]; then
    JAVA_CMD="${JAVA_CMD} --assets ${ASSET_PACK}"
fi

if [ "${ACCEPT_EARLY_PLUGINS:-0}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --accept-early-plugins"
fi

JAVA_CMD="${JAVA_CMD} --auth-mode ${AUTH_MODE:-authenticated}"

if [ -n "${LOGGER_LEVEL:-}" ]; then
    JAVA_CMD="${JAVA_CMD} --log ${LOGGER_LEVEL}"
fi

if [ "${VALIDATE_WORLD_GENERATION:-0}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --validate-world-gen"
fi

if [ "${VALIDATE_ASSETS:-0}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --validate-assets"
fi

if [ -n "${VALIDATE_PREFABS:-}" ]; then
    JAVA_CMD="${JAVA_CMD} --validate-prefabs ${VALIDATE_PREFABS}"
fi

if [ "${ALLOW_OP:-1}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --allow-op"
fi

if [ "${DISABLE_SENTRY:-1}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --disable-sentry"
fi

if [ -n "${BOOT_COMMANDS:-}" ]; then
    JAVA_CMD="${JAVA_CMD} --boot-command ${BOOT_COMMANDS}"
fi

if [ "${FORCE_NETWORK_FLUSH:-0}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --force-network-flush"
fi

if [ "${EVENT_DEBUG:-0}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --event-debug"
fi

if [ "${ENABLE_BACKUPS:-0}" = "1" ]; then
    JAVA_CMD="${JAVA_CMD} --backup --backup-dir ./backup --backup-frequency ${BACKUP_FREQUENCY:-30} --backup-max-count ${MAXIMUM_BACKUPS:-5}"
fi

if [ -n "${SESSION_TOKEN:-}" ]; then
    JAVA_CMD="${JAVA_CMD} --session-token ${SESSION_TOKEN}"
else
    echo "Warning: SESSION_TOKEN is not set"
fi
if [ -n "${IDENTITY_TOKEN:-}" ]; then
    JAVA_CMD="${JAVA_CMD} --identity-token ${IDENTITY_TOKEN}"
else
    echo "Warning: IDENTITY_TOKEN is not set"
fi

JAVA_CMD="${JAVA_CMD} --bind 0.0.0.0:${SERVER_PORT:-5520}"

exec $JAVA_CMD
EOF

  chmod 755 "$INSTALL_DIR/start.sh"
}

write_systemd_units() {
  local SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
  local SOCKET_UNIT="/etc/systemd/system/${SERVICE_NAME}.socket"
  local RUNTIME_SOCKET="/run/${SERVICE_NAME}.socket"

  cat > "$SYSTEMD_UNIT" << 'EOF'
[Unit]
Description=Hytale Server
Documentation=https://hytale.com/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=hytale-srv
Group=hytale-srv

Sockets={{SERVICE_NAME}}.socket
StandardInput=socket
StandardOutput=journal
StandardError=journal
SyslogIdentifier={{SERVICE_NAME}}

NoNewPrivileges=true
ProtectHome=yes

MemoryLimit=16G
CPUQuota=400%
TasksMax=512
LimitNOFILE=65536

WorkingDirectory={{INSTALL_DIR}}
EnvironmentFile=-/etc/default/{{SERVICE_NAME}}
ExecStart={{INSTALL_DIR}}/entrypoint.sh

KillMode=process
KillSignal=SIGTERM
TimeoutStopSec=30

Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SOCKET_UNIT" << 'EOF'
[Unit]
Description=Hytale Server Console Socket
Documentation=https://hytale.com/
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

  sed -i "s|{{INSTALL_DIR}}|$INSTALL_DIR|g" "$SYSTEMD_UNIT"
  sed -i "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" "$SYSTEMD_UNIT"
  sed -i "s|{{RUNTIME_SOCKET}}|$RUNTIME_SOCKET|g" "$SOCKET_UNIT"
  sed -i "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" "$SOCKET_UNIT"
}

write_defaults_file() {
  cat > "$DEFAULTS_FILE" << EOF
SERVER_PORT=${SERVER_PORT:-5520}
PATCHLINE=${PATCHLINE:-release}
AUTOMATIC_UPDATE=${AUTOMATIC_UPDATE:-1}
SERVER_MEMORY=${SERVER_MEMORY:-8192}
MEMORY_OVERHEAD=${MEMORY_OVERHEAD:-0}
JVM_ARGS=${JVM_ARGS:-}
AUTH_MODE=${AUTH_MODE:-authenticated}
LEVERAGE_AHEAD_OF_TIME_CACHE=${LEVERAGE_AHEAD_OF_TIME_CACHE:-1}
DISABLE_SENTRY=${DISABLE_SENTRY:-1}
ALLOW_OP=${ALLOW_OP:-1}
ENABLE_BACKUPS=${ENABLE_BACKUPS:-0}
BACKUP_FREQUENCY=${BACKUP_FREQUENCY:-30}
MAXIMUM_BACKUPS=${MAXIMUM_BACKUPS:-5}
ACCEPT_EARLY_PLUGINS=${ACCEPT_EARLY_PLUGINS:-0}
VALIDATE_ASSETS=${VALIDATE_ASSETS:-0}
VALIDATE_PREFABS=${VALIDATE_PREFABS:-}
VALIDATE_WORLD_GENERATION=${VALIDATE_WORLD_GENERATION:-0}
LOGGER_LEVEL=${LOGGER_LEVEL:-}
BOOT_COMMANDS=${BOOT_COMMANDS:-}
FORCE_NETWORK_FLUSH=${FORCE_NETWORK_FLUSH:-0}
EVENT_DEBUG=${EVENT_DEBUG:-0}
ENFORCE_PERMISSIONS=${ENFORCE_PERMISSIONS:-0}
GAME_PROFILE=${GAME_PROFILE:-}
USE_PERSISTENT_AUTHENTICATION=${USE_PERSISTENT_AUTHENTICATION:-ENABLED}
EOF
}

fix_qemu_paths() {
  if [ "$(uname -m)" = "aarch64" ]; then
    sed -i "s|/opt/hytale-INSTANCE|$INSTALL_DIR|g" "$INSTALL_DIR/hytale-downloader-linux-arm64" "$INSTALL_DIR/entrypoint.sh" 2>/dev/null || true
  fi
}

fix_permissions() {
  chown -R "$HYTALE_USER:$HYTALE_GROUP" "$INSTALL_DIR"
  chmod 750 "$INSTALL_DIR"
  chmod 755 "$INSTALL_DIR/entrypoint.sh" "$INSTALL_DIR/start.sh"
}

echo "[*] Hytale Server Installer"
echo ""

# Step 1: Create dedicated user and group
printf "[1] Setting up dedicated user: %s\n" "$HYTALE_USER"
create_hytale_user

# Step 2: Install dependencies
echo "[2] Installing dependencies"
install_deps

# Step 3: Create directories
echo "[3] Setting up directories"
setup_directories

# Step 4: Install Java 25
echo "[4] Checking Java runtime"
ensure_java25

# Step 5: Download Hytale downloader
echo "[5] Installing Hytale downloader"
install_downloader

# Step 6: Write scripts
echo "[6] Writing entrypoint and helper scripts"
write_lib_scripts
write_entrypoint
write_start_script

# Step 7: Create systemd service + socket
echo "[7] Creating systemd units"
write_systemd_units

# Step 8: Write defaults file
echo "[8] Writing runtime defaults"
write_defaults_file

# Step 9: Fix ARM paths + permissions
echo "[9] Finalizing permissions"
fix_qemu_paths
fix_permissions

# Step 10: Reload systemd and enable
echo "[10] Finalizing systemd configuration"
systemctl daemon-reload
systemctl enable ${SERVICE_NAME}.service 2>/dev/null || true
systemctl enable ${SERVICE_NAME}.socket 2>/dev/null || true
systemctl start ${SERVICE_NAME}.socket 2>/dev/null || true

echo ""
echo "✅ Installation Complete!"
echo ""
echo "📋 Next Steps:"
echo "   1. Start: sudo systemctl start ${SERVICE_NAME}"
echo "   2. Check logs: sudo journalctl -u ${SERVICE_NAME} -f"
echo "   3. First start will prompt for authentication"
echo ""
echo "🔒 Security Notes:"
echo "   • Server runs as non-root user: $HYTALE_USER"
echo "   • ProtectHome=yes, NoNewPrivileges=true"
echo "   • Java 25 enforced"
