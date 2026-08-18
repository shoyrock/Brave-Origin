#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# In-Container Automatic Brave Origin Update Script
# Explicit 2-Stage (Download-First -> No-Download Install) Update Transaction
# ==============================================================================

LOCK_FILE="/run/lock/brave-origin-update.lock"
FLAG_RESTART="/tmp/brave-restart.flag"
PID_FILE="/tmp/brave.pid"
STATE_DIR="/config/state"
LAST_VERSION_FILE="${STATE_DIR}/last-brave-version"
MIN_FREE_MB="${MIN_UPDATE_FREE_SPACE_MB:-1024}"

mkdir -p /run/lock "${STATE_DIR}" 2>/dev/null || true

# 1. Acquire Shared Non-Blocking Update Lock
exec 200>"${LOCK_FILE}"
if ! flock -n 200; then
    echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Another update process is currently active. Skipping."
    exit 0
fi

MODE="${1:---manual}"
TIMESTAMP="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
echo "========================================================"
echo "[updater] [${TIMESTAMP}] Update check initiated (Mode: ${MODE})"
echo "========================================================"

# 2. Conservative Root Filesystem Space Pre-Check
MIN_FREE_KB=$(( MIN_FREE_MB * 1024 ))
ROOT_FREE_KB=$(df -k / 2>/dev/null | awk 'NR==2 {print $4}' || echo "0")

if [ "${ROOT_FREE_KB}" -lt "${MIN_FREE_KB}" ]; then
    echo "[updater] [${TIMESTAMP}] Warning: Insufficient root disk space (${ROOT_FREE_KB} KB available, ${MIN_FREE_KB} KB required). Aborting upgrade."
    exit 0
fi

# 3. Read Last Successfully Used Profile Version
LAST_USED_VER=""
if [ -f "${LAST_VERSION_FILE}" ]; then
    LAST_USED_VER="$(tr -d '[:space:]' < "${LAST_VERSION_FILE}")"
elif [ -f "/config/.last-brave-version" ]; then
    LAST_USED_VER="$(tr -d '[:space:]' < "/config/.last-brave-version")"
fi

if [ -n "${LAST_USED_VER}" ]; then
    echo "[updater] [${TIMESTAMP}] Profile last recorded version: ${LAST_USED_VER}"
fi

# 4. Verify Official Brave APT Repository Configuration
KEYRING_PATH="/usr/share/keyrings/brave-browser-archive-keyring.gpg"
SOURCES_PATH="/etc/apt/sources.list.d/brave-browser-release.sources"

if [ ! -f "${KEYRING_PATH}" ]; then
    echo "[updater] [${TIMESTAMP}] Restoring official Brave archive keyring..."
    curl -fsSLo "${KEYRING_PATH}" \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg 2>/dev/null || {
        echo "[updater] [${TIMESTAMP}] Warning: Unable to download Brave keyring."
    }
fi

if [ ! -f "${SOURCES_PATH}" ]; then
    echo "[updater] [${TIMESTAMP}] Restoring official Brave repository sources..."
    curl -fsSLo "${SOURCES_PATH}" \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources 2>/dev/null || {
        echo "[updater] [${TIMESTAMP}] Warning: Unable to download Brave sources file."
    }
fi

# 5. Refresh APT Repository Metadata
echo "[updater] [${TIMESTAMP}] Refreshing package metadata from official Brave repository..."
REPO_AVAILABLE=true
if ! apt-get update -o Dir::Etc::sourcelist="sources.list.d/brave-browser-release.sources" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" -qq 2>/dev/null; then
    if ! apt-get update -qq 2>/dev/null; then
        echo "[updater] [${TIMESTAMP}] Warning: APT repository refresh failed (network offline or repository unreachable)."
        REPO_AVAILABLE=false
    fi
fi

# 6. Determine Current Installed Version
INSTALLED_VER=$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "none")
echo "[updater] [${TIMESTAMP}] Installed version: ${INSTALLED_VER}"

# 7. Determine Available Candidate Version & Respect Version Pinning
PINNED_VER="${BRAVE_ORIGIN_VERSION:-latest}"
CANDIDATE_VER=""
if [ "${REPO_AVAILABLE}" = "true" ]; then
    CANDIDATE_VER=$(apt-cache policy brave-origin 2>/dev/null | grep 'Candidate:' | awk '{print $2}' || echo "")
    if [ -n "${CANDIDATE_VER}" ]; then
        echo "[updater] [${TIMESTAMP}] Available repository candidate: ${CANDIDATE_VER}"
    fi
fi

TARGET_VER=""
if [ "${PINNED_VER}" = "latest" ] || [ -z "${PINNED_VER}" ]; then
    TARGET_VER="${CANDIDATE_VER}"
else
    TARGET_VER="${PINNED_VER}"
    echo "[updater] [${TIMESTAMP}] Version pinning active: ${TARGET_VER}"
fi

# 8. Evaluate Target Version with Debian-Semantics Downgrade Check
if [ -n "${LAST_USED_VER}" ] && [ -n "${TARGET_VER}" ] && [ "${TARGET_VER}" != "none" ]; then
    if dpkg --compare-versions "${TARGET_VER}" "lt" "${LAST_USED_VER}"; then
        echo "[updater] [${TIMESTAMP}] Downgrade protection: Target version (${TARGET_VER}) is older than profile version (${LAST_USED_VER}). Prohibiting install."
        TARGET_VER=""
    fi
fi

# 9. Two-Stage Update Execution
if [ -n "${TARGET_VER}" ] && [ "${TARGET_VER}" != "none" ]; then
    UPGRADE_NEEDED=false
    if [ "${INSTALLED_VER}" = "none" ]; then
        UPGRADE_NEEDED=true
    elif dpkg --compare-versions "${TARGET_VER}" "gt" "${INSTALLED_VER}"; then
        UPGRADE_NEEDED=true
    fi

    if [ "${UPGRADE_NEEDED}" = "true" ]; then
        echo "[updater] [${TIMESTAMP}] Update available: ${INSTALLED_VER} -> ${TARGET_VER}"
        export DEBIAN_FRONTEND=noninteractive

        # ----------------------------------------------------------------------
        # STAGE 1: Download packages while Brave remains actively running
        # ----------------------------------------------------------------------
        echo "[updater] [${TIMESTAMP}] Stage 1/2: Pre-downloading package archives (Brave remains online)..."
        DOWNLOAD_SUCCESS=false
        DOWNLOAD_ERR=""

        if [ "${PINNED_VER}" != "latest" ] && [ -n "${PINNED_VER}" ]; then
            if apt-get install -y --download-only --no-install-recommends "brave-origin=${TARGET_VER}" >/dev/null 2>&1; then
                DOWNLOAD_SUCCESS=true
            fi
        else
            if apt-get install -y --download-only --no-install-recommends brave-origin >/dev/null 2>&1; then
                DOWNLOAD_SUCCESS=true
            fi
        fi

        if [ "${DOWNLOAD_SUCCESS}" != "true" ]; then
            echo "[updater] [${TIMESTAMP}] Package download failed (network or repository unreachable). Existing browser remains running safely."
            exit 0
        fi

        echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Pre-download verified. All required archives are cached locally."

        # ----------------------------------------------------------------------
        # STAGE 2: Gracefully stop Brave, then install strictly offline (--no-download)
        # ----------------------------------------------------------------------
        if [ -f "${PID_FILE}" ]; then
            BRAVE_PID=$(cat "${PID_FILE}" 2>/dev/null || echo "")
            if [ -n "${BRAVE_PID}" ] && kill -0 "${BRAVE_PID}" 2>/dev/null; then
                echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Stopping Brave process (PID ${BRAVE_PID}) for offline package installation..."
                kill -TERM "${BRAVE_PID}" 2>/dev/null || true

                for i in $(seq 1 15); do
                    if ! kill -0 "${BRAVE_PID}" 2>/dev/null; then
                        break
                    fi
                    sleep 1
                done

                if kill -0 "${BRAVE_PID}" 2>/dev/null; then
                    echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Escalating to SIGKILL..."
                    kill -KILL "${BRAVE_PID}" 2>/dev/null || true
                fi
            fi
        fi

        echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Stage 2/2: Installing strictly from local cache (--no-download)..."
        INSTALL_SUCCESS=false

        if [ "${PINNED_VER}" != "latest" ] && [ -n "${PINNED_VER}" ]; then
            if apt-get install -y --no-download --no-install-recommends "brave-origin=${TARGET_VER}" >/dev/null 2>&1; then
                INSTALL_SUCCESS=true
            fi
        else
            if apt-get install -y --no-download --no-install-recommends brave-origin >/dev/null 2>&1; then
                INSTALL_SUCCESS=true
            fi
        fi

        if [ "${INSTALL_SUCCESS}" = "true" ]; then
            NEW_INSTALLED_VER=$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "unknown")
            echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Upgrade complete. Installed version: ${NEW_INSTALLED_VER}"
            INSTALLED_VER="${NEW_INSTALLED_VER}"

            # Clean cached package archives
            apt-get clean 2>/dev/null || true

            # Signal supervisor to launch updated browser
            touch "${FLAG_RESTART}"
        else
            echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Offline install encountered error. Performing automatic recovery..."
            dpkg --configure -a >/dev/null 2>&1 || true
            apt-get -f install -y >/dev/null 2>&1 || true

            # Check if working binary remains
            CURRENT_BIN_VER=$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "none")
            if [ "${CURRENT_BIN_VER}" != "none" ]; then
                echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Package consistency restored. Relaunching version: ${CURRENT_BIN_VER}"
                touch "${FLAG_RESTART}"
            else
                echo "[updater] [$(date -u +'%Y-%m-%d %H:%M:%S UTC')] Critical: brave-origin package missing after install attempt."
                exit 1
            fi
        fi
    else
        if [ "${INSTALLED_VER}" = "${TARGET_VER}" ]; then
            echo "[updater] [${TIMESTAMP}] Brave Origin is up to date (${INSTALLED_VER})."
        fi
    fi
else
    if [ "${REPO_AVAILABLE}" = "false" ]; then
        echo "[updater] [${TIMESTAMP}] Repository unavailable. Keeping currently installed version (${INSTALLED_VER})."
    fi
fi

# 10. Final Downgrade Condition Status
if [ -n "${LAST_USED_VER}" ] && [ "${INSTALLED_VER}" != "none" ]; then
    if dpkg --compare-versions "${INSTALLED_VER}" "lt" "${LAST_USED_VER}"; then
        echo "[updater] [${TIMESTAMP}] Downgrade protection active: Installed (${INSTALLED_VER}) < Profile (${LAST_USED_VER})."
        exit 2
    fi
fi

echo "========================================================"
exit 0
