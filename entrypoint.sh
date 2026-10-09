#!/usr/bin/env bash
# ==============================================================================
# Brave Origin Native Wayland Docker Appliance (Selkies + Pixelflux + Labwc)
# ==============================================================================
set -eo pipefail

if [ "${BRAVE_STORAGE_READY:-}" != 1 ]; then
    exec python3 /usr/local/bin/prepare-storage.py "$@"
fi
unset BRAVE_STORAGE_READY

echo "========================================================"
echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Starting Brave Origin in Docker (Native Wayland / Selkies)"
echo "========================================================"

# Trap termination signals for clean shutdown
cleanup() {
    trap - SIGINT SIGTERM SIGHUP
    echo ""
    echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Caught shutdown signal, initiating graceful stop..."
    
    # Let the session close Brave before stopping its display and audio servers.
    if [ "${SESSION_PID:-0}" -gt 0 ]; then
        pkill -TERM -P "$SESSION_PID" -u braveuser 2>/dev/null || true
    fi
    nginx -s stop 2>/dev/null || true

    # The profile lock (/config/state/profile.lock) is released automatically
    # when the session processes exit
    
    # Give the browser time to flush its profile.
    for ((i=0; i<20; i++)); do
        if [ "${SESSION_PID:-0}" -eq 0 ] || ! kill -0 "$SESSION_PID" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    pkill -KILL -u braveuser 2>/dev/null || true
    echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Container stopped."
    exit 0
}

trap cleanup SIGINT SIGTERM SIGHUP

# 1. PUID / PGID and UMASK Handling
TARGET_UID="${PUID:-1000}"
TARGET_GID="${PGID:-1000}"
TARGET_UMASK="${UMASK:-022}"

if ! [[ "${TARGET_UID}" =~ ^[1-9][0-9]{0,9}$ ]] || (( TARGET_UID > 2147483647 )); then
    echo 'PUID must be a nonzero user ID.' >&2
    exit 1
fi
if ! [[ "${TARGET_GID}" =~ ^[1-9][0-9]{0,9}$ ]] || (( TARGET_GID > 2147483647 )); then
    echo 'PGID must be a nonzero group ID.' >&2
    exit 1
fi
[[ "${TARGET_UMASK}" =~ ^0?[0-7]{3}$ ]] || { echo 'UMASK must be an octal permissions mask.' >&2; exit 1; }
for setting in UPDATE_INTERVAL DOWNGRADE_RETRY_INTERVAL MIN_UPDATE_FREE_SPACE_MB BRAVE_STARTUP_TIMEOUT DISPLAY_WIDTH DISPLAY_HEIGHT; do
    value="${!setting}"
    if [ -n "$value" ] && { [[ ! "$value" =~ ^[1-9][0-9]*$ ]] || (( ${#value} > 9 )); }; then
        echo "$setting must be a positive integer." >&2; exit 1
    fi
done
case "${DISPLAY_AUTO_RESIZE:-true}" in
    true|false) ;;
    *) echo 'DISPLAY_AUTO_RESIZE must be true or false.' >&2; exit 1 ;;
esac
case "${BROWSER_LOCK_MAXIMIZED:-true}" in
    true|false) ;;
    *) echo 'BROWSER_LOCK_MAXIMIZED must be true or false.' >&2; exit 1 ;;
esac
umask "${TARGET_UMASK}"

# Storage preparation holds the instance lock on descriptor 7.
install -m 0666 /dev/null /run/lock/brave-origin-launch.lock

echo "[supervisor] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Configuring container user permissions (UID: ${TARGET_UID}, GID: ${TARGET_GID}, UMASK: ${TARGET_UMASK})..."

CURRENT_UID=$(id -u braveuser)
CURRENT_GID=$(id -g braveuser)

if [ "${CURRENT_GID}" -ne "${TARGET_GID}" ]; then
    groupmod -o -g "${TARGET_GID}" braveuser
fi

if [ "${CURRENT_UID}" -ne "${TARGET_UID}" ] || [ "${CURRENT_GID}" -ne "${TARGET_GID}" ]; then
    usermod -o -u "${TARGET_UID}" -g "${TARGET_GID}" braveuser
fi

# Ensure render and video group access for hardware acceleration
if [ -e "${DRI_NODE:-/dev/dri/renderD128}" ]; then
    RENDER_GID=$(stat -c '%g' "${DRI_NODE:-/dev/dri/renderD128}" 2>/dev/null || echo "")
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

# Persistent paths and ownership were validated before the supervisor started.
mkdir -p /etc/nginx/ssl /etc/nginx/conf.d

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
RAW_AUTH="${AUTH_ENABLED:-${KASM_AUTH_ENABLED:-true}}"
AUTH_ENABLED_LOWER="$(echo "${RAW_AUTH}" | tr '[:upper:]' '[:lower:]')"

if [ "${AUTH_ENABLED_LOWER}" != "true" ] && [ "${AUTH_ENABLED_LOWER}" != "false" ]; then
    echo "[nginx] ERROR: Invalid AUTH_ENABLED value '${RAW_AUTH}'! Must be 'true' or 'false'." >&2
    exit 1
fi

if [ "${AUTH_ENABLED_LOWER}" = "true" ]; then
    PASSWD_FILE="/config/.passwd"
    
    AUTH_USER_VAL="${AUTH_USER:-${KASM_USER:-brave}}"
    AUTH_PASS_VAL="${AUTH_PASSWORD:-${KASM_PASSWORD:-}}"
    
    if [ ! -f "${PASSWD_FILE}" ]; then
        AUTH_PASS_FILE_VAL="${AUTH_PASSWORD_FILE:-${KASM_PASSWORD_FILE:-}}"
        if [ -n "${AUTH_PASS_FILE_VAL}" ]; then
            [ -r "${AUTH_PASS_FILE_VAL}" ] || { echo 'Password file is unreadable.' >&2; exit 1; }
            SECRET_PASS="$(tr -d '\r\n' < "${AUTH_PASS_FILE_VAL}")"
            [ -n "${SECRET_PASS}" ] || { echo 'Password file is empty.' >&2; exit 1; }
            echo "[nginx] Creating initial credentials from mounted secret file for user '${AUTH_USER_VAL}'..."
            printf '%s\n' "${SECRET_PASS}" | htpasswd -iBc "${PASSWD_FILE}" "${AUTH_USER_VAL}" >/dev/null 2>&1
            chmod 640 "${PASSWD_FILE}"
            chown root:www-data "${PASSWD_FILE}"
        elif [ -n "${AUTH_PASS_VAL}" ]; then
            echo "[nginx] Creating initial credentials from environment variables for user '${AUTH_USER_VAL}'..."
            printf '%s\n' "${AUTH_PASS_VAL}" | htpasswd -iBc "${PASSWD_FILE}" "${AUTH_USER_VAL}" >/dev/null 2>&1
            chmod 640 "${PASSWD_FILE}"
            chown root:www-data "${PASSWD_FILE}"
        else
            echo "[nginx] ERROR: AUTH_ENABLED=true but no authentication credentials exist!" >&2
            echo "[nginx] Provide AUTH_PASSWORD_FILE, AUTH_PASSWORD, or run reset-password.sh." >&2
            exit 1
        fi
    fi
    chmod 640 "${PASSWD_FILE}"
    chown root:www-data "${PASSWD_FILE}"
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
# Hosts without IPv6 (disabled kernels, IPv4-only runtimes) must still start.
rm -f /etc/nginx/conf.d/listen-ipv6.conf
if python3 -c 'import socket; socket.socket(socket.AF_INET6).bind(("::", 0))' 2>/dev/null; then
    echo 'listen [::]:8443 ssl default_server;' > /etc/nginx/conf.d/listen-ipv6.conf
else
    echo "[nginx] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] IPv6 is unavailable; listening on IPv4 only."
fi
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

# Pass settings as environment entries, never as shell source. Credentials stay
# in the supervisor and nginx; the browser receives only session settings.
launch_session() {
    local name
    local -a session_env=("HOME=/config" "USER=braveuser" "LOGNAME=braveuser" "PATH=/usr/local/bin:/usr/bin:/bin" "LANG=C.UTF-8")
    for name in ENABLE_AUDIO ENABLE_GPU BRAVE_FLAGS DRI_NODE TZ BROWSER_LOCK_MAXIMIZED DISPLAY_AUTO_RESIZE DISPLAY_WIDTH DISPLAY_HEIGHT DOWNGRADE_RETRY_INTERVAL; do
        [ -z "${!name}" ] || session_env+=("${name}=${!name}")
    done
    runuser -u braveuser -- env -i "${session_env[@]}" bash -c 'exec /usr/local/bin/start-session.sh >> /config/state/session.log 2>&1' 7>&- &
    SESSION_PID=$!
}
if [ ! -f /config/state/quiesce.flag ]; then
    launch_session
else
    SESSION_PID=0
fi

# 9. Background Watchdog and Periodic Updater Loop
LAST_UPDATE_CHECK=$(date +%s)
UPDATE_INTERVAL="${UPDATE_INTERVAL:-21600}"

while true; do
    sleep 5

    # Check if the session stopped or a backup hold was released
    if [ "${SESSION_PID}" = 0 ] || ! kill -0 "${SESSION_PID}" 2>/dev/null; then
        if [ -f /config/state/quiesce.flag ]; then
            # profile-control.sh quiesce is active (backup in progress); do not relaunch
            : # Stay paused without repeating a message on every watchdog tick.
        else
            echo "[watchdog] [$(date -u +"%Y-%m-%d %H:%M:%S UTC")] Session process terminated! Restarting session..."
            launch_session
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
