#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# Brave Origin Profile Backup Consistency Hook
# Provides quiesce, resume, and status operations for external backup/snapshot tools
# ==============================================================================

STATE_DIR="/config/state"
STATUS_FILE="${STATE_DIR}/status"
QUIESCE_FLAG="${STATE_DIR}/quiesce.flag"
PID_FILE="/tmp/brave.pid"
STARTUP_TIMEOUT="${BRAVE_STARTUP_TIMEOUT:-15}"

mkdir -p "${STATE_DIR}" 2>/dev/null || true

set_status_atomic() {
    local status="$1"
    local tmp="${STATUS_FILE}.tmp.$$"
    printf '%s\n' "${status}" > "${tmp}" 2>/dev/null || return 0
    chmod 644 "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${STATUS_FILE}" 2>/dev/null || rm -f "${tmp}" 2>/dev/null || true
}

get_current_status() {
    if [ -f "${QUIESCE_FLAG}" ]; then
        echo "QUIESCED"
    elif [ -f "${PID_FILE}" ] && kill -0 "$(cat "${PID_FILE}" 2>/dev/null)" 2>/dev/null; then
        # A live browser is authoritative: never mask it with a stale status file
        echo "RUNNING"
    elif [ -f "${STATUS_FILE}" ]; then
        tr -d '[:space:]' < "${STATUS_FILE}"
    else
        echo "STARTING"
    fi
}

ACTION="${1:-status}"

case "${ACTION}" in
    quiesce)
        TIMESTAMP="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
        echo "[supervisor] [${TIMESTAMP}] Quiesce requested: preparing /config for backup/snapshot..."

        # Set quiesce flag to prevent supervisor from automatically relaunching Brave
        touch "${QUIESCE_FLAG}"

        # 1. Gracefully stop running Brave process
        if [ -f "${PID_FILE}" ]; then
            BRAVE_PID="$(cat "${PID_FILE}" 2>/dev/null || echo "")"
            if [ -n "${BRAVE_PID}" ] && kill -0 "${BRAVE_PID}" 2>/dev/null; then
                echo "[supervisor] [${TIMESTAMP}] Gracefully stopping Brave Origin (PID ${BRAVE_PID})..."
                kill -TERM "${BRAVE_PID}" 2>/dev/null || true

                # Wait up to 15 seconds for clean exit and SQLite database commit
                for i in $(seq 1 15); do
                    if ! kill -0 "${BRAVE_PID}" 2>/dev/null; then
                        break
                    fi
                    sleep 1
                done

                if kill -0 "${BRAVE_PID}" 2>/dev/null; then
                    echo "[supervisor] [${TIMESTAMP}] Warning: Brave lingering after timeout. Escalating to SIGKILL..."
                    kill -KILL "${BRAVE_PID}" 2>/dev/null || true
                    sleep 1
                fi
            fi
        fi

        # 2. Flush and synchronize filesystem writes to disk
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Flushing filesystem writes to persistent storage..."
        if ! sync -f /config 2>/dev/null && ! sync; then
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] ERROR: Filesystem sync failed. /config is NOT backup-ready." >&2
            rm -f "${QUIESCE_FLAG}" 2>/dev/null || true
            set_status_atomic "ERROR"
            exit 1
        fi

        # 3. Only report QUIESCED after process exit and successful sync
        set_status_atomic "QUIESCED"
        echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Quiesce complete: /config is synchronized and ready for backup/snapshot."
        exit 0
        ;;

    resume)
        TIMESTAMP="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
        echo "[supervisor] [${TIMESTAMP}] Resume requested: releasing backup hold..."

        # Remove quiesce flag
        rm -f "${QUIESCE_FLAG}"
        set_status_atomic "STARTING"

        # Signal supervisor to resume
        touch /tmp/brave-restart.flag

        # Wait for Brave to reach running status
        SUCCESS=false
        for i in $(seq 1 "${STARTUP_TIMEOUT}"); do
            if [ -f "${PID_FILE}" ]; then
                BRAVE_PID="$(cat "${PID_FILE}" 2>/dev/null || echo "")"
                if [ -n "${BRAVE_PID}" ] && kill -0 "${BRAVE_PID}" 2>/dev/null; then
                    SUCCESS=true
                    break
                fi
            fi
            sleep 1
        done

        if [ "${SUCCESS}" = "true" ]; then
            set_status_atomic "RUNNING"
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Resume complete: Brave Origin is running (PID ${BRAVE_PID})."
            exit 0
        else
            echo "[supervisor] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Resume notice: Brave startup is pending or in recovery."
            exit 0
        fi
        ;;

    status)
        STATUS="$(get_current_status)"
        echo "${STATUS}"
        exit 0
        ;;

    *)
        echo "Usage: $0 {quiesce|resume|status}" >&2
        exit 1
        ;;
esac
