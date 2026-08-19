#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# KasmVNC Desktop Session & Brave Origin Supervisor
# Robust Process Management, Profile flock, Watchdog & Bounded Crash-Loop Backoff
# ==============================================================================

STATE_DIR="/config/state"
PROFILE_DIR="/config/profile"
LAST_VERSION_FILE="${STATE_DIR}/last-brave-version"
PROFILE_LOCK_FILE="${STATE_DIR}/profile.lock"
STATUS_FILE="${STATE_DIR}/status"
QUIESCE_FLAG="${STATE_DIR}/quiesce.flag"
PID_FILE="/tmp/brave.pid"

mkdir -p "${STATE_DIR}" "${PROFILE_DIR}" /config/downloads /tmp/brave-cache 2>/dev/null || true

# Backward-compatibility migration: move /config/.last-brave-version if present
if [ -f "/config/.last-brave-version" ] && [ ! -f "${LAST_VERSION_FILE}" ]; then
    mv -f "/config/.last-brave-version" "${LAST_VERSION_FILE}" 2>/dev/null || true
fi

set_status_atomic() {
    local status="$1"
    local tmp="${STATUS_FILE}.tmp.$$"
    printf '%s\n' "${status}" > "${tmp}" 2>/dev/null || return 0
    chmod 644 "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${STATUS_FILE}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null || true
}

record_version_atomic() {
    local version="$1"
    local tmp="${LAST_VERSION_FILE}.tmp.$$"
    if [ -z "${version}" ] || [ "${version}" = "unknown" ]; then
        return 0
    fi
    if printf '%s\n' "${version}" > "${tmp}" 2>/dev/null; then
        sync -f "${tmp}" 2>/dev/null || sync || true
        chmod 600 "${tmp}" 2>/dev/null || true
        if mv -f "${tmp}" "${LAST_VERSION_FILE}" 2>/dev/null; then
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Atomically updated profile version: ${version} in ${LAST_VERSION_FILE}"
        else
            rm -f "${tmp}" 2>/dev/null || true
        fi
    else
        rm -f "${tmp}" 2>/dev/null || true
    fi
}

export DISPLAY="${DISPLAY:-:1}"
export HOME="${HOME:-/config}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-braveuser}"
unset WAYLAND_DISPLAY
export XDG_SESSION_TYPE=x11

echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Initializing graphical desktop session on DISPLAY=${DISPLAY}..."

# 1. Start private D-Bus session
if command -v dbus-launch >/dev/null 2>&1; then
    eval "$(dbus-launch --sh-syntax)" || true
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] D-Bus session active (PID: ${DBUS_SESSION_BUS_PID:-unknown})"
fi

# 2. Wait for X server display readiness before starting window manager or applications
echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Verifying X server readiness on ${DISPLAY}..."
X_READY=false
for i in $(seq 1 50); do
    if command -v xdpyinfo >/dev/null 2>&1; then
        if xdpyinfo -display "${DISPLAY}" >/dev/null 2>&1; then
            X_READY=true
            break
        fi
    elif [ -S "/tmp/.X11-unix/X${DISPLAY#*:}" ]; then
        X_READY=true
        break
    fi
    sleep 0.2
done

if [ "${X_READY}" = "true" ]; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] X server is active and responding on ${DISPLAY}."
else
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Warning: X server readiness timed out on ${DISPLAY}. Proceeding with launch..."
fi

# 3. Configure and start Openbox window manager
mkdir -p /config/.config/openbox
if [ ! -f /config/.config/openbox/rc.xml ] && [ -f /etc/xdg/openbox/rc.xml ]; then
    cp /etc/xdg/openbox/rc.xml /config/.config/openbox/rc.xml
fi

echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Starting Openbox window manager..."
openbox --config-file /config/.config/openbox/rc.xml &
OPENBOX_PID=$!
sleep 0.5
if kill -0 "${OPENBOX_PID}" 2>/dev/null; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Openbox window manager running (PID: ${OPENBOX_PID})."
else
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Warning: Openbox window manager process did not stay running." >&2
fi

# 4. Audio setup
AUDIO_PID=""
start_audio_relay() {
    if [ "${ENABLE_AUDIO:-true}" = "true" ] && [ -f "/usr/local/bin/audio-server.py" ]; then
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Starting Internal Audio WebSocket Relay on 127.0.0.1:4901..."
        BIND_HOST="127.0.0.1" AUDIO_PORT="4901" python3 /usr/local/bin/audio-server.py >> "${STATE_DIR}/audio-relay.log" 2>&1 &
        AUDIO_PID=$!
        sleep 0.5
        if kill -0 "${AUDIO_PID}" 2>/dev/null; then
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Audio relay running (PID: ${AUDIO_PID})."
        fi
    fi
}

check_audio_relay() {
    if [ "${ENABLE_AUDIO:-true}" = "true" ] && [ -f "/usr/local/bin/audio-server.py" ]; then
        if [ -z "${AUDIO_PID}" ] || ! kill -0 "${AUDIO_PID}" 2>/dev/null; then
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Audio relay not running. Relaunching..."
            start_audio_relay
        fi
    fi
}

if [ "${ENABLE_AUDIO:-true}" = "true" ]; then
    if [ -n "${PULSE_SERVER}" ]; then
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Using external PulseAudio server: ${PULSE_SERVER}"
    else
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Starting internal PulseAudio daemon..."
        pulseaudio --start --exit-idle-time=-1 --daemonize=true >/dev/null 2>&1 || true
        # Actively wait for PulseAudio readiness (bounded loop: max 3s)
        for i in $(seq 1 30); do
            if pactl info >/dev/null 2>&1; then
                echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] PulseAudio is active and responding."
                break
            fi
            sleep 0.1
        done
        # Ensure at least one sink is available for PulseAudio
        if ! pactl list short sinks | grep -q 's16le\|float32'; then
            pactl load-module module-null-sink sink_name=auto_null sink_properties=device.description=Auto_Null >/dev/null 2>&1 || true
        fi
    fi
    start_audio_relay
fi

# 5. Locate official Brave Origin binary
BRAVE_BIN=""
if command -v brave-origin >/dev/null 2>&1; then
    BRAVE_BIN="brave-origin"
elif [ -x "/opt/brave.com/brave-origin/brave" ]; then
    BRAVE_BIN="/opt/brave.com/brave-origin/brave"
elif [ -x "/opt/brave.com/brave-origin/brave-origin" ]; then
    BRAVE_BIN="/opt/brave.com/brave-origin/brave-origin"
fi

if [ -z "${BRAVE_BIN}" ]; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Error: Brave Origin binary not found!" >&2
    set_status_atomic "ERROR"
    exit 1
fi

echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Brave Origin executable located: ${BRAVE_BIN}"

# 6. Configure Brave Origin runtime flags (Preserving Chromium Sandbox & Ozone X11)
BRAVE_ARGS=(
    "--ozone-platform=x11"
    "--user-data-dir=${PROFILE_DIR}"
    "--disk-cache-dir=/tmp/brave-cache"
    "--default-download-directory=/config/downloads"
    "--no-first-run"
    "--no-default-browser-check"
    "--password-store=basic"
    "--start-maximized"
    "--window-position=0,0"
    "--window-size=${DISPLAY_WIDTH:-1920},${DISPLAY_HEIGHT:-1080}"
)

# Optional GPU Rendering vs Software Rendering Fallback
if [ "${ENABLE_GPU:-true}" = "false" ]; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] GPU rendering explicitly disabled via ENABLE_GPU=false. Using software rendering (--disable-gpu)."
    BRAVE_ARGS+=("--disable-gpu")
elif [ -e "${DRI_NODE:-/dev/dri/renderD128}" ]; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Hardware DRI node detected (${DRI_NODE:-/dev/dri/renderD128}). GPU acceleration enabled."
else
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] DRI device not present. Defaulting to software rendering (--disable-gpu)."
    BRAVE_ARGS+=("--disable-gpu")
fi

SHM_SIZE_KB=$(df -k /dev/shm 2>/dev/null | awk 'NR==2 {print $2}' || echo "0")
if [ "${SHM_SIZE_KB}" -lt 262144 ]; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Warning: /dev/shm is smaller than 256MB (${SHM_SIZE_KB} KB). Falling back to --disable-dev-shm-usage."
    BRAVE_ARGS+=("--disable-dev-shm-usage")
fi

if [ -n "${BRAVE_FLAGS}" ]; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Appending custom flags: ${BRAVE_FLAGS}"
    read -ra USER_FLAGS <<< "${BRAVE_FLAGS}"
    BRAVE_ARGS+=("${USER_FLAGS[@]}")
fi

# 6. Persistent Space Warning (Separate from root check)
check_config_disk_space() {
    local config_free_kb
    config_free_kb=$(df -k /config 2>/dev/null | awk 'NR==2 {print $4}' || echo "1000000")
    if [ "${config_free_kb}" -lt 51200 ]; then
        echo "================================================================================"
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] WARNING: Persistent storage /config is critically low on space (${config_free_kb} KB free)."
        echo "[supervisor] Please expand host storage or free up space in downloads/."
        echo "================================================================================"
    fi
}

# 7. Safe Stale Singleton Cleanup (Only when all conditions met)
safe_clean_singleton_artifacts() {
    # 1. flock on profile.lock must be held (caller verifies)
    # 2. No active browser process running in container
    local active_browser_pids
    active_browser_pids=$(pgrep -f "/opt/brave.com/brave-origin/brave" 2>/dev/null || true)

    if [ -z "${active_browser_pids}" ]; then
        if [ -e "${PROFILE_DIR}/SingletonLock" ] || [ -L "${PROFILE_DIR}/SingletonLock" ] || \
           [ -e "${PROFILE_DIR}/SingletonSocket" ] || [ -L "${PROFILE_DIR}/SingletonSocket" ] || \
           [ -e "${PROFILE_DIR}/SingletonCookie" ] || [ -L "${PROFILE_DIR}/SingletonCookie" ]; then
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Stale Chromium singleton artifacts safely removed (profile lock acquired, no active browser process)."
            rm -f "${PROFILE_DIR}/SingletonLock" "${PROFILE_DIR}/SingletonSocket" "${PROFILE_DIR}/SingletonCookie" 2>/dev/null || true
        fi
    fi
}

RECOVERY_INTERVAL="${DOWNGRADE_RETRY_INTERVAL:-300}"
STARTUP_TIMEOUT="${BRAVE_STARTUP_TIMEOUT:-15}"

# 8. Acquire Project-Level Exclusive Profile Lock (Held for lifetime of supervisor/browser)
exec 300>"${PROFILE_LOCK_FILE}"
if ! flock -n 300; then
    echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] ERROR: Profile lock (${PROFILE_LOCK_FILE}) is held by another process." >&2
    echo "[supervisor] Only one supervised Brave instance may access ${PROFILE_DIR} at a time." >&2
    set_status_atomic "ERROR"
    exit 1
fi
echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Acquired authoritative profile lock on ${PROFILE_LOCK_FILE}"

# 9. Main Supervisor & Watchdog Loop with Bounded Crash Backoff
echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Brave Origin supervisor & watchdog active."

CONSECUTIVE_FAILURES=0

handle_crash_backoff() {
    CONSECUTIVE_FAILURES=$(( CONSECUTIVE_FAILURES + 1 ))

    case "${CONSECUTIVE_FAILURES}" in
        1)
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Watchdog backoff: Rapid failure #1. Cooling down for 10s..."
            sleep 10
            ;;
        2)
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Watchdog backoff: Rapid failure #2. Cooling down for 30s..."
            sleep 30
            ;;
        3)
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Watchdog backoff: Rapid failure #3. Cooling down for 60s..."
            sleep 60
            ;;
        *)
            echo "================================================================================"
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] ERROR: Repeated startup failures exceeded limit (${CONSECUTIVE_FAILURES} consecutive crashes)."
            echo "[supervisor] Watchdog paused in ERROR state to protect system resources."
            echo "[supervisor] Restart container or touch /tmp/brave-restart.flag to retry."
            echo "================================================================================"
            set_status_atomic "ERROR"

            # Wait in paused error state until explicit restart signal or container shutdown
            while [ ! -f /tmp/brave-restart.flag ] && [ ! -f /tmp/container-stopping.flag ]; do
                sleep 2
            done

            if [ -f /tmp/brave-restart.flag ]; then
                echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Restart signal received. Resetting watchdog failure counter..."
                rm -f /tmp/brave-restart.flag
                CONSECUTIVE_FAILURES=0
            fi
            ;;
    esac
}

while true; do
    # Check if container is stopping
    if [ -f /tmp/container-stopping.flag ]; then
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Container stop signal detected. Exiting supervisor."
        break
    fi

    # Check if snapshot/backup quiesce is requested
    if [ -f "${QUIESCE_FLAG}" ]; then
        set_status_atomic "QUIESCED"
        sleep 1
        continue
    fi

    check_config_disk_space

    # Determine installed package version
    CURRENT_VER=$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "unknown")

    # Read last recorded profile version
    LAST_RECORDED_VER=""
    if [ -f "${LAST_VERSION_FILE}" ]; then
        LAST_RECORDED_VER="$(tr -d '[:space:]' < "${LAST_VERSION_FILE}")"
    fi

    # Evaluate Downgrade Protection with Debian package-version semantics
    if [ -n "${LAST_RECORDED_VER}" ] && [ "${CURRENT_VER}" != "unknown" ]; then
        if dpkg --compare-versions "${CURRENT_VER}" "lt" "${LAST_RECORDED_VER}"; then
            echo "================================================================================"
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] [DOWNGRADE BLOCKED] Profile Protection Active"
            echo "[supervisor] Installed Version : ${CURRENT_VER}"
            echo "[supervisor] Profile Version   : ${LAST_RECORDED_VER} (from ${LAST_VERSION_FILE})"
            echo "[supervisor] Launching ${CURRENT_VER} against a profile created by ${LAST_RECORDED_VER} is blocked."
            echo "[supervisor] Entering recovery mode (retrying official repository every ${RECOVERY_INTERVAL}s)..."
            echo "================================================================================"
            set_status_atomic "DOWNGRADE_RECOVERY"

            # Recovery Loop
            while dpkg --compare-versions "${CURRENT_VER}" "lt" "${LAST_RECORDED_VER}"; do
                if [ -f /tmp/container-stopping.flag ]; then
                    break 2
                fi

                sleep "${RECOVERY_INTERVAL}" || true

                if [ -f /tmp/container-stopping.flag ]; then
                    break 2
                fi

                echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Downgrade recovery retry: Checking official repository..."
                /usr/local/bin/update-brave.sh --recovery >/dev/null 2>&1 || true

                CURRENT_VER=$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "unknown")
            done

            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Downgrade protection cleared! Compatible version installed: ${CURRENT_VER} (>= ${LAST_RECORDED_VER})"
        fi
    fi

    # Check quiesce state before launching
    if [ -f "${QUIESCE_FLAG}" ]; then
        set_status_atomic "QUIESCED"
        sleep 1
        continue
    fi

    # Safely clean stale Chromium singletons
    safe_clean_singleton_artifacts

    # Bounded Brave Diagnostic Log Management
    BRAVE_LOG="${STATE_DIR}/brave.log"
    if [ -f "${BRAVE_LOG}" ] && [ "$(stat -c%s "${BRAVE_LOG}" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        tail -n 500 "${BRAVE_LOG}" > "${BRAVE_LOG}.tmp" && mv -f "${BRAVE_LOG}.tmp" "${BRAVE_LOG}"
    fi

    # Ensure audio relay daemon is active if ENABLE_AUDIO=true
    check_audio_relay

    set_status_atomic "STARTING"
    echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Launching Brave Origin (Version: ${CURRENT_VER})..."
    "${BRAVE_BIN}" "${BRAVE_ARGS[@]}" 2>&1 | tee -a "${BRAVE_LOG}" &
    BRAVE_PID=$!
    echo "${BRAVE_PID}" > "${PID_FILE}"

    # Startup Verification Loop (up to STARTUP_TIMEOUT)
    START_TIME=$(date +%s)
    STABLE=false

    for i in $(seq 1 "${STARTUP_TIMEOUT}"); do
        sleep 1
        if ! kill -0 "${BRAVE_PID}" 2>/dev/null; then
            echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Error: Brave process exited prematurely during startup verification." >&2
            echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] --- Recent Brave Startup Diagnostics (${BRAVE_LOG}) ---" >&2
            tail -n 50 "${BRAVE_LOG}" >&2 || true
            echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] ---------------------------------------------------" >&2
            set_status_atomic "ERROR"
            handle_crash_backoff
            break
        fi

        ELAPSED=$(( $(date +%s) - START_TIME ))
        # Minimum stabilization requirement: 4 seconds continuous execution
        if [ "${ELAPSED}" -ge 4 ]; then
            STABLE=true
            break
        fi
    done

    if [ "${STABLE}" = "true" ]; then
        echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Brave Origin startup verified active and stable (PID: ${BRAVE_PID})."
        set_status_atomic "RUNNING"
        record_version_atomic "${CURRENT_VER}"
    fi

    # Wait for browser process termination
    wait "${BRAVE_PID}" || true
    EXIT_CODE=$?
    rm -f "${PID_FILE}"
    LIFETIME=$(( $(date +%s) - START_TIME ))

    # If the browser ran stably (lifetime >= 5s and exit code == 0, or lifetime >= 30s), reset consecutive failure counter
    if [ "${LIFETIME}" -ge 30 ] || ([ "${LIFETIME}" -ge 5 ] && [ "${EXIT_CODE}" -eq 0 ]); then
        CONSECUTIVE_FAILURES=0
    fi

    # Check if restart was requested by updater or profile-control
    if [ -f /tmp/brave-restart.flag ]; then
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Restart flag detected. Relaunching Brave Origin..."
        rm -f /tmp/brave-restart.flag
        CONSECUTIVE_FAILURES=0
        sleep 1
        continue
    fi

    if [ -f "${QUIESCE_FLAG}" ]; then
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Quiesce hold active. Waiting for resume signal..."
        set_status_atomic "QUIESCED"
        sleep 1
        continue
    fi

    if [ -f /tmp/container-stopping.flag ]; then
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Container stopping. Terminating session."
        break
    fi

    # Application Watchdog: Detect crash vs user closing browser window
    if [ "${LIFETIME}" -lt 5 ] || [ "${EXIT_CODE}" -ne 0 ]; then
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Watchdog: Brave Origin exited unexpectedly (Code: ${EXIT_CODE}, Uptime: ${LIFETIME}s)." >&2
        echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] --- Recent Brave Diagnostics (${BRAVE_LOG}) ---" >&2
        tail -n 50 "${BRAVE_LOG}" >&2 || true
        echo "[brave] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] ---------------------------------------------------" >&2
        handle_crash_backoff
    else
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Watchdog: Brave Origin window closed. Automatically relaunching in 2 seconds..."
        sleep 2
    fi
done

# Release profile lock when supervisor terminates
flock -u 300 2>/dev/null || true
exec 300>&- 2>/dev/null || true

# Cleanup Audio Relay
if [ -n "${AUDIO_PID}" ] && kill -0 "${AUDIO_PID}" 2>/dev/null; then
    kill -TERM "${AUDIO_PID}" 2>/dev/null || true
fi

# Cleanup Openbox
if [ -n "${OPENBOX_PID}" ] && kill -0 "${OPENBOX_PID}" 2>/dev/null; then
    kill -TERM "${OPENBOX_PID}" 2>/dev/null || true
fi
