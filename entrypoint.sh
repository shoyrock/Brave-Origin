#!/usr/bin/env bash
# ==============================================================================
# Brave Origin Native Wayland Docker Appliance (Selkies + Pixelflux + Labwc)
# ==============================================================================
set -e

echo "========================================================"
echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Starting Brave Origin in Docker (Native Wayland / Selkies)"
echo "========================================================"

# Trap termination signals for clean shutdown
cleanup() {
    echo ""
    echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Caught shutdown signal, initiating graceful stop..."
    
    # Terminate session and background processes
    pkill -TERM -u braveuser || true
    nginx -s stop 2>/dev/null || true
    
    # Release profile lock if held
    /usr/local/bin/profile-control.sh release 2>/dev/null || true
    
    # Wait up to 3 seconds for processes to exit cleanly
    sleep 2
    pkill -KILL -u braveuser 2>/dev/null || true
    echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Container stopped."
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

# 1. PUID / PGID and UMASK Handling
TARGET_UID="${PUID:-1000}"
TARGET_GID="${PGID:-1000}"
TARGET_UMASK="${UMASK:-022}"

umask "${TARGET_UMASK}"

echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Configuring container user permissions (UID: ${TARGET_UID}, GID: ${TARGET_GID}, UMASK: ${TARGET_UMASK})..."

CURRENT_UID=$(id -u braveuser)
CURRENT_GID=$(id -g braveuser)

if [ "${CURRENT_GID}" -ne "${TARGET_GID}" ]; then
    groupmod -o -g "${TARGET_GID}" braveuser
fi

if [ "${CURRENT_UID}" -ne "${TARGET_UID}" ]; then
    usermod -o -u "${TARGET_UID}" -g "${TARGET_GID}" braveuser
fi

# Ensure render and video group access for hardware acceleration
if [ -e "/dev/dri/renderD128" ]; then
    RENDER_GID=$(stat -c '%g' /dev/dri/renderD128 2>/dev/null || echo "")
    if [ -n "${RENDER_GID}" ] && [ "${RENDER_GID}" -ne 0 ]; then
        groupadd -g "${RENDER_GID}" hostrender 2>/dev/null || true
        usermod -aG "${RENDER_GID}" braveuser 2>/dev/null || true
    fi
fi

# 2. Timezone Configuration
if [ -n "${TZ}" ] && [ -f "/usr/share/zoneinfo/${TZ}" ]; then
    ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
    echo "${TZ}" > /etc/timezone
    echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Timezone configured: ${TZ}"
fi

# 3. Persistent Directory Structure
mkdir -p /config/profile \
         /config/downloads \
         /config/state \
         /config/ssl \
         /etc/nginx/ssl \
         /etc/nginx/conf.d \
         /tmp/runtime-braveuser \
         /tmp/brave-cache

chmod 700 /tmp/runtime-braveuser

# Fast non-recursive ownership configuration for runtime directories
chown "${TARGET_UID}:${TARGET_GID}" /config /config/profile /config/downloads /config/state /config/ssl /tmp/runtime-braveuser /tmp/brave-cache
chown "${TARGET_UID}:${TARGET_GID}" /config/state/* 2>/dev/null || true

# 4. Generate Self-Signed SSL/TLS Certificates for HTTPS
if [ ! -f "/config/ssl/cert.pem" ] || [ ! -f "/config/ssl/cert.key" ]; then
    echo "[nginx] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Generating self-signed SSL/TLS certificate..."
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
        -keyout /config/ssl/cert.key \
        -out /config/ssl/cert.pem \
        -subj "/C=US/ST=State/L=City/O=BraveOrigin/CN=brave-origin.internal" >/dev/null 2>&1
    chmod 600 /config/ssl/cert.key
fi

cp -f /config/ssl/cert.pem /etc/nginx/ssl/nginx.crt
cp -f /config/ssl/cert.key /etc/nginx/ssl/nginx.key
chmod 644 /etc/nginx/ssl/nginx.crt
chmod 600 /etc/nginx/ssl/nginx.key

# 5. Authentication Configuration
rm -f /etc/nginx/conf.d/auth.conf

# Support both AUTH_ENABLED and legacy KASM_AUTH_ENABLED
RAW_AUTH="${AUTH_ENABLED:-${KASM_AUTH_ENABLED:-false}}"
AUTH_ENABLED_LOWER="$(echo "${RAW_AUTH}" | tr '[:upper:]' '[:lower:]')"

if [ "${AUTH_ENABLED_LOWER}" != "true" ] && [ "${AUTH_ENABLED_LOWER}" != "false" ]; then
    echo "[nginx] ERROR: Invalid AUTH_ENABLED value '${RAW_AUTH}'! Must be 'true' or 'false'." >&2
    exit 1
fi

if [ "${AUTH_ENABLED_LOWER}" = "true" ]; then
    PASSWD_FILE="/config/.passwd"
    [ -f "/config/.kasmpasswd" ] && [ ! -f "${PASSWD_FILE}" ] && cp /config/.kasmpasswd "${PASSWD_FILE}"
    
    AUTH_USER_VAL="${AUTH_USER:-${KASM_USER:-brave}}"
    AUTH_PASS_VAL="${AUTH_PASSWORD:-${KASM_PASSWORD:-}}"
    
    if [ ! -f "${PASSWD_FILE}" ]; then
        AUTH_PASS_FILE_VAL="${AUTH_PASSWORD_FILE:-${KASM_PASSWORD_FILE:-}}"
        if [ -n "${AUTH_PASS_FILE_VAL}" ] && [ -f "${AUTH_PASS_FILE_VAL}" ]; then
            SECRET_PASS="$(tr -d '\r\n' < "${AUTH_PASS_FILE_VAL}")"
            echo "[nginx] Creating initial credentials from mounted secret file for user '${AUTH_USER_VAL}'..."
            htpasswd -bc "${PASSWD_FILE}" "${AUTH_USER_VAL}" "${SECRET_PASS}" >/dev/null 2>&1
            chmod 644 "${PASSWD_FILE}"
            chown "${TARGET_UID}:${TARGET_GID}" "${PASSWD_FILE}"
        elif [ -n "${AUTH_PASS_VAL}" ]; then
            echo "[nginx] Creating initial credentials from environment variables for user '${AUTH_USER_VAL}'..."
            htpasswd -bc "${PASSWD_FILE}" "${AUTH_USER_VAL}" "${AUTH_PASS_VAL}" >/dev/null 2>&1
            chmod 644 "${PASSWD_FILE}"
            chown "${TARGET_UID}:${TARGET_GID}" "${PASSWD_FILE}"
        else
            echo "[nginx] ERROR: AUTH_ENABLED=true but no authentication credentials exist!" >&2
            echo "[nginx] Provide AUTH_PASSWORD_FILE, AUTH_PASSWORD, or run reset-password.sh." >&2
            exit 1
        fi
    fi
    echo 'auth_basic "Brave Origin Authentication Required";' > /etc/nginx/conf.d/auth.conf
    echo "auth_basic_user_file ${PASSWD_FILE};" >> /etc/nginx/conf.d/auth.conf
    echo "[nginx] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Authentication mode: ENABLED"
else
    echo "[nginx] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Authentication mode: DISABLED"
fi

# 6. Startup Update Check & Downgrade Assessment
if [ "${AUTO_UPDATE:-true}" = "true" ]; then
    echo "[updater] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Performing startup update verification..."
    /usr/local/bin/update-brave.sh --startup || true
fi

# 7. Start Nginx Ingress Proxy
echo "[nginx] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Initializing Single-Origin TLS Reverse Proxy on port 8443..."
nginx -t >/dev/null 2>&1 || nginx -t
nginx

INSTALLED_VER=$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "Unknown")
PROFILE_VER=$(cat /config/state/last-brave-version 2>/dev/null || echo "None (new profile)")

echo "========================================================"
echo " Brave Origin Native Wayland Server Ready!"
echo " URL:                 https://localhost:8443"
echo " Protocol:            Native Wayland / Ozone (Selkies + Pixelflux + Labwc)"
echo " Authentication:      $([ "${AUTH_ENABLED_LOWER}" = "true" ] && echo "Enabled" || echo "Disabled")"
echo " Audio Streaming:     ${ENABLE_AUDIO:-true} (Unified WebSocket Opus)"
echo " Installed Version:   ${INSTALLED_VER}"
echo " Profile Version:     ${PROFILE_VER}"
echo " Update Interval:     ${UPDATE_INTERVAL:-21600}s"
echo "========================================================"

# 8. Launch Native Wayland Session under Unprivileged User with Profile Lock
# NOTE: `su -` strips the environment, so session-relevant variables must be passed explicitly.
su - braveuser -c "ENABLE_AUDIO=${ENABLE_AUDIO:-true} ENABLE_GPU=${ENABLE_GPU:-true} BRAVE_FLAGS='${BRAVE_FLAGS:-}' /usr/local/bin/start-session.sh" >> /config/state/session.log 2>&1 &
SESSION_PID=$!

# 9. Background Watchdog and Periodic Updater Loop
LAST_UPDATE_CHECK=$(date +%s)
UPDATE_INTERVAL="${UPDATE_INTERVAL:-21600}"

while true; do
    sleep 5

    # Check if main session process has terminated unexpectedly
    if ! kill -0 "${SESSION_PID}" 2>/dev/null; then
        if [ -f /config/state/quiesce.flag ]; then
            # profile-control.sh quiesce is active (backup in progress); do not relaunch
            echo "[watchdog] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Session terminated but quiesce flag is set - waiting for resume."
        else
            echo "[watchdog] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Session process terminated! Restarting session..."
            su - braveuser -c "ENABLE_AUDIO=${ENABLE_AUDIO:-true} ENABLE_GPU=${ENABLE_GPU:-true} BRAVE_FLAGS='${BRAVE_FLAGS:-}' /usr/local/bin/start-session.sh" >> /config/state/session.log 2>&1 &
            SESSION_PID=$!
        fi
    fi
    
    # Check if Nginx proxy is running
    if ! pgrep -x nginx >/dev/null 2>&1; then
        echo "[watchdog] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Nginx crashed! Restarting Nginx..."
        nginx || true
    fi
    
    # Periodic update check
    if [ "${AUTO_UPDATE:-true}" = "true" ]; then
        CURRENT_TIME=$(date +%s)
        ELAPSED=$((CURRENT_TIME - LAST_UPDATE_CHECK))
        if [ "${ELAPSED}" -ge "${UPDATE_INTERVAL}" ]; then
            echo "[updater] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Running periodic update check..."
            /usr/local/bin/update-brave.sh --cron || true
            LAST_UPDATE_CHECK=$(date +%s)
        fi
    fi
done
