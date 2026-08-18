#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# Brave Origin KasmVNC Container Entrypoint
# Production Process Supervisor, Dynamic Permissions & Environment Initializer
# ==============================================================================

# 1. Environment Defaults & Validation
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
UMASK="${UMASK:-022}"
TZ="${TZ:-UTC}"
WEB_PORT="${WEB_PORT:-8443}"
DISPLAY_WIDTH="${DISPLAY_WIDTH:-1920}"
DISPLAY_HEIGHT="${DISPLAY_HEIGHT:-1080}"
KASM_AUTH_ENABLED="${KASM_AUTH_ENABLED:-false}"
KASM_USER="${KASM_USER:-brave}"
KASM_PASSWORD="${KASM_PASSWORD:-}"
KASM_PASSWORD_FILE="${KASM_PASSWORD_FILE:-}"
AUTO_UPDATE="${AUTO_UPDATE:-true}"
UPDATE_INTERVAL="${UPDATE_INTERVAL:-21600}"
DOWNGRADE_RETRY_INTERVAL="${DOWNGRADE_RETRY_INTERVAL:-300}"
MIN_UPDATE_FREE_SPACE_MB="${MIN_UPDATE_FREE_SPACE_MB:-1024}"
BRAVE_STARTUP_TIMEOUT="${BRAVE_STARTUP_TIMEOUT:-15}"
BRAVE_ORIGIN_VERSION="${BRAVE_ORIGIN_VERSION:-latest}"
ENABLE_GPU="${ENABLE_GPU:-true}"
ENABLE_AUDIO="${ENABLE_AUDIO:-true}"
DRI_NODE="${DRI_NODE:-/dev/dri/renderD128}"

# Apply user-configured file creation mask
umask "${UMASK}"

# Strict parsing of KASM_AUTH_ENABLED (accept true/false case-insensitively)
KASM_AUTH_ENABLED_LOWER="$(echo "${KASM_AUTH_ENABLED}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
if [ "${KASM_AUTH_ENABLED_LOWER}" != "true" ] && [ "${KASM_AUTH_ENABLED_LOWER}" != "false" ]; then
    echo "================================================================================" >&2
    echo "[kasmvnc] ERROR: Invalid KASM_AUTH_ENABLED value '${KASM_AUTH_ENABLED}'!" >&2
    echo "Valid options are 'true' or 'false'." >&2
    echo "================================================================================" >&2
    exit 1
fi

export PUID PGID UMASK TZ WEB_PORT DISPLAY_WIDTH DISPLAY_HEIGHT KASM_AUTH_ENABLED
export AUTO_UPDATE UPDATE_INTERVAL DOWNGRADE_RETRY_INTERVAL MIN_UPDATE_FREE_SPACE_MB
export BRAVE_STARTUP_TIMEOUT BRAVE_ORIGIN_VERSION ENABLE_GPU ENABLE_AUDIO DRI_NODE
export HOME=/config
export DISPLAY=:1
export XDG_RUNTIME_DIR=/tmp/runtime-braveuser

echo "========================================================"
echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Starting Brave Origin in Docker (KasmVNC)"
echo "========================================================"

# 2. Configure Dynamic User & Group Permissions
echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Configuring container user permissions (UID: ${PUID}, GID: ${PGID}, UMASK: ${UMASK})..."

if [ "$(id -g braveuser 2>/dev/null)" != "${PGID}" ]; then
    groupmod -o -g "${PGID}" braveuser 2>/dev/null || true
fi

if [ "$(id -u braveuser 2>/dev/null)" != "${PUID}" ]; then
    usermod -o -u "${PUID}" -g "${PGID}" braveuser 2>/dev/null || true
fi

# Ensure user belongs to ssl-cert group
adduser braveuser ssl-cert >/dev/null 2>&1 || true

# 3. Configure Timezone
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Timezone configured: ${TZ}"
fi

# 4. Prepare Directory Hierarchy & Clean Up Stale Locks
echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Setting up persistent and runtime storage paths..."
mkdir -p /config/profile \
         /config/downloads \
         /config/kasmvnc/certs \
         /config/state \
         /config/.config/openbox \
         /config/.vnc \
         /tmp/brave-cache \
         /tmp/.X11-unix \
         /tmp/runtime-braveuser \
         /run/lock

# Backward-compatibility migration: move /config/.last-brave-version if present
if [ -f "/config/.last-brave-version" ] && [ ! -f "/config/state/last-brave-version" ]; then
    mv -f "/config/.last-brave-version" "/config/state/last-brave-version" 2>/dev/null || true
fi

# Remove legacy plaintext credentials file if previously generated (preserving .kasmpasswd)
rm -f /config/kasmvnc/credentials.txt 2>/dev/null || true

rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 /tmp/*.pid /tmp/*.flag /run/lock/brave-origin-update.lock 2>/dev/null || true

chmod 1777 /tmp/.X11-unix /run/lock
chmod 700 /tmp/runtime-braveuser /tmp/brave-cache

# Configure official Chromium SUID sandbox permissions
if [ -f "/opt/brave.com/brave-origin/chrome-sandbox" ]; then
    chown root:root /opt/brave.com/brave-origin/chrome-sandbox 2>/dev/null || true
    chmod 4755 /opt/brave.com/brave-origin/chrome-sandbox 2>/dev/null || true
    export CHROME_DEVEL_SANDBOX="/opt/brave.com/brave-origin/chrome-sandbox"
fi

# 5. SSL / TLS Certificate Setup
CERT_FILE="/config/kasmvnc/certs/kasmvnc.pem"
KEY_FILE="/config/kasmvnc/certs/kasmvnc.key"

if [ ! -f "${CERT_FILE}" ] || [ ! -f "${KEY_FILE}" ]; then
    echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Generating self-signed SSL/TLS certificate..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout "${KEY_FILE}" \
        -out "${CERT_FILE}" \
        -subj "/C=US/ST=State/L=City/O=BraveOrigin/CN=brave-origin" >/dev/null 2>&1
    chmod 600 "${KEY_FILE}" "${CERT_FILE}"
fi

# 6. KasmVNC Authentication Setup
KASMPASSWD_FILE="/config/kasmvnc/.kasmpasswd"

if [ "${KASM_AUTH_ENABLED_LOWER}" = "true" ]; then
    echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Authentication mode: ENABLED"
    
    # Credential precedence:
    # 1. KASM_PASSWORD_FILE if explicitly configured and readable
    # 2. KASM_PASSWORD if explicitly configured
    # 3. Existing /config/kasmvnc/.kasmpasswd
    if [ -n "${KASM_PASSWORD_FILE}" ]; then
        if [ -f "${KASM_PASSWORD_FILE}" ]; then
            KASM_PASSWORD="$(cat "${KASM_PASSWORD_FILE}" 2>/dev/null || echo "")"
            if [ -z "${KASM_PASSWORD}" ]; then
                echo "================================================================================" >&2
                echo "[kasmvnc] ERROR: KASM_PASSWORD_FILE (${KASM_PASSWORD_FILE}) is empty or unreadable!" >&2
                echo "================================================================================" >&2
                exit 1
            fi
            echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Configuring credentials for user '${KASM_USER}' from secret file..."
            printf "%s\n%s\n" "${KASM_PASSWORD}" "${KASM_PASSWORD}" | \
                kasmvncpasswd -u "${KASM_USER}" -rwo "${KASMPASSWD_FILE}" >/dev/null 2>&1
            chmod 600 "${KASMPASSWD_FILE}" 2>/dev/null || true
        else
            echo "================================================================================" >&2
            echo "[kasmvnc] ERROR: Configured KASM_PASSWORD_FILE (${KASM_PASSWORD_FILE}) not found inside container!" >&2
            echo "Ensure host secret file is mounted into the container at this path." >&2
            echo "================================================================================" >&2
            exit 1
        fi
    elif [ -n "${KASM_PASSWORD}" ]; then
        echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Configuring credentials for user '${KASM_USER}' from environment variable..."
        printf "%s\n%s\n" "${KASM_PASSWORD}" "${KASM_PASSWORD}" | \
            kasmvncpasswd -u "${KASM_USER}" -rwo "${KASMPASSWD_FILE}" >/dev/null 2>&1
        chmod 600 "${KASMPASSWD_FILE}" 2>/dev/null || true
    elif [ -f "${KASMPASSWD_FILE}" ]; then
        echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Using existing credentials from ${KASMPASSWD_FILE}."
        chmod 600 "${KASMPASSWD_FILE}" 2>/dev/null || true
    else
        echo "================================================================================" >&2
        echo "[kasmvnc] ERROR: KASM_AUTH_ENABLED=true but no authentication credentials exist!" >&2
        echo "" >&2
        echo "To configure credentials, choose one of the following methods:" >&2
        echo "" >&2
        echo "1. Set KASM_PASSWORD_FILE pointing to a mounted secret file inside container (Recommended):" >&2
        echo "   KASM_PASSWORD_FILE=/run/secrets/kasm_password" >&2
        echo "" >&2
        echo "2. Set KASM_PASSWORD in your environment / .env file:" >&2
        echo "   KASM_PASSWORD=MySecurePassword123!" >&2
        echo "" >&2
        echo "3. Or generate credentials interactively before starting the container:" >&2
        echo "   docker compose run --rm brave-origin /usr/local/bin/reset-password.sh --generate" >&2
        echo "================================================================================" >&2
        exit 1
    fi
else
    echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Authentication mode: DISABLED (Network-Level Protection)"
    if [ ! -f "${KASMPASSWD_FILE}" ]; then
        printf "nopassword\nnopassword\n" | kasmvncpasswd -u default -rwo "${KASMPASSWD_FILE}" >/dev/null 2>&1 || true
        chmod 600 "${KASMPASSWD_FILE}" 2>/dev/null || true
    fi
fi

# 7. Configure KasmVNC YAML Settings (Explicit Port, Resolution & Encoding)
CONFIG_YAML="/config/kasmvnc/kasmvnc.yaml"
if [ ! -f "${CONFIG_YAML}" ]; then
    echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Initializing KasmVNC configuration..."
    cp /etc/kasmvnc/kasmvnc.yaml "${CONFIG_YAML}"
fi

# Ensure explicit configured port and resolution in kasmvnc.yaml
sed -i "s/websocket_port: .*/websocket_port: ${WEB_PORT}/g" "${CONFIG_YAML}" || true
sed -i "s/width: .*/width: ${DISPLAY_WIDTH}/g" "${CONFIG_YAML}" || true
sed -i "s/height: .*/height: ${DISPLAY_HEIGHT}/g" "${CONFIG_YAML}" || true

# Check GPU DRI node availability
if [ -e "${DRI_NODE}" ] && [ "${ENABLE_GPU}" = "true" ]; then
    echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] DRI GPU node detected (${DRI_NODE}). Enabling hw3d."
    sed -i "s/hw3d: false/hw3d: true/g" "${CONFIG_YAML}" || true
    # Add video group permission if DRI node exists
    DRI_GID=$(stat -c '%g' "${DRI_NODE}" 2>/dev/null || echo "")
    if [ -n "${DRI_GID}" ] && [ "${DRI_GID}" -ne 0 ]; then
        groupadd -g "${DRI_GID}" -o render_group 2>/dev/null || true
        usermod -aG "${DRI_GID}" braveuser 2>/dev/null || true
    fi
else
    sed -i "s/hw3d: true/hw3d: false/g" "${CONFIG_YAML}" || true
fi

# Create user VNC symlinks
ln -snf /config/kasmvnc/kasmvnc.yaml /config/.vnc/kasmvnc.yaml
ln -snf /config/kasmvnc/.kasmpasswd /config/.kasmpasswd
ln -snf /config/kasmvnc/.kasmpasswd /config/.vnc/passwd 2>/dev/null || true

# 8. User and Storage Permissions Handling
chown -R braveuser:braveuser /config /tmp/runtime-braveuser /tmp/brave-cache /tmp/.X11-unix

# 9. Startup Update Check & Downgrade Assessment
LAST_VERSION_FILE="/config/state/last-brave-version"
LAST_RECORDED_VER=""
if [ -f "${LAST_VERSION_FILE}" ]; then
    LAST_RECORDED_VER="$(tr -d '[:space:]' < "${LAST_VERSION_FILE}")"
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Profile last recorded version: ${LAST_RECORDED_VER}"
fi

echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Performing startup update verification..."
/usr/local/bin/update-brave.sh --startup || {
    echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Startup update check completed with non-fatal status."
}

INSTALLED_BRAVE=$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "unknown")

if [ -n "${LAST_RECORDED_VER}" ] && [ "${INSTALLED_BRAVE}" != "unknown" ]; then
    if dpkg --compare-versions "${INSTALLED_BRAVE}" "lt" "${LAST_RECORDED_VER}"; then
        echo "================================================================================"
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] [DOWNGRADE PROTECTION ACTIVE]"
        echo "[supervisor] Installed Version : ${INSTALLED_BRAVE}"
        echo "[supervisor] Profile Version   : ${LAST_RECORDED_VER}"
        echo "[supervisor] Browser launch is paused. Supervisor will retry repository updates"
        echo "[supervisor] every ${DOWNGRADE_RETRY_INTERVAL}s while KasmVNC remains accessible."
        echo "================================================================================"
    fi
fi

# 10. Start Background Periodic Update Loop (if enabled)
CONTAINER_RUNNING=true
UPDATE_PID=""

start_update_loop() {
    echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Periodic update daemon active (Interval: ${UPDATE_INTERVAL}s)."
    while [ "${CONTAINER_RUNNING}" = "true" ]; do
        sleep "${UPDATE_INTERVAL}" || true
        if [ "${CONTAINER_RUNNING}" != "true" ]; then
            break
        fi
        echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Scheduled update check starting..."
        /usr/local/bin/update-brave.sh --periodic || {
            echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Scheduled update check finished with non-fatal status."
        }
    done
}

if [ "${AUTO_UPDATE}" = "true" ] || [ "${AUTO_UPDATE}" = "1" ]; then
    start_update_loop &
    UPDATE_PID=$!
fi

# 11. Graceful Shutdown Signal Handler
cleanup() {
    echo ""
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Caught termination signal. Stopping services..."
    CONTAINER_RUNNING=false
    touch /tmp/container-stopping.flag

    # Stop update daemon
    if [ -n "${UPDATE_PID}" ] && kill -0 "${UPDATE_PID}" 2>/dev/null; then
        kill -TERM "${UPDATE_PID}" 2>/dev/null || true
    fi

    # Gracefully stop Brave Origin first
    if [ -f /tmp/brave.pid ]; then
        BRAVE_PID=$(cat /tmp/brave.pid 2>/dev/null || echo "")
        if [ -n "${BRAVE_PID}" ] && kill -0 "${BRAVE_PID}" 2>/dev/null; then
            echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Requesting graceful shutdown (PID ${BRAVE_PID})..."
            kill -TERM "${BRAVE_PID}" 2>/dev/null || true
            for i in $(seq 1 10); do
                if ! kill -0 "${BRAVE_PID}" 2>/dev/null; then break; fi
                sleep 0.5
            done
        fi
    fi

    # Stop KasmVNC server session
    echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Stopping KasmVNC server..."
    gosu braveuser vncserver -kill :1 >/dev/null 2>&1 || true

    # Clean temporary locks
    rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 /tmp/*.flag /tmp/*.pid /run/lock/brave-origin-update.lock 2>/dev/null || true
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Clean shutdown complete. Exiting."
    exit 0
}

trap cleanup SIGTERM SIGINT SIGHUP SIGQUIT

# 12. Display Readiness Summary
echo "========================================================"
echo " Brave Origin KasmVNC Server Ready!"
echo " URL:                 https://localhost:${WEB_PORT}"
if [ "${KASM_AUTH_ENABLED_LOWER}" = "true" ]; then
    echo " Authentication:      Enabled (HTTP Basic Auth, User: ${KASM_USER})"
else
    echo " Authentication:      Disabled (Network-Level Protection)"
fi
echo " Installed Version:   ${INSTALLED_BRAVE}"
echo " Profile Version:     ${LAST_RECORDED_VER:-None (new profile)}"
echo " Update Interval:     ${UPDATE_INTERVAL}s (Downgrade Recovery: ${DOWNGRADE_RETRY_INTERVAL}s)"
echo "========================================================"

# 13. Drop privileges and start KasmVNC server
VNC_OPTS=(
    -config /config/kasmvnc/kasmvnc.yaml
    -geometry "${DISPLAY_WIDTH}x${DISPLAY_HEIGHT}"
    -depth 24
    -websocketPort "${WEB_PORT}"
    -xstartup /usr/local/bin/start-session.sh
    -fg
)

if [ "${KASM_AUTH_ENABLED_LOWER}" = "false" ]; then
    VNC_OPTS+=("-disableBasicAuth" "-SecurityTypes" "None")
fi

echo "[kasmvnc] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Launching KasmVNC on display :1 (HTTPS port ${WEB_PORT}, Auth: ${KASM_AUTH_ENABLED_LOWER})..."
exec gosu braveuser vncserver :1 "${VNC_OPTS[@]}"
