#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# KasmVNC Password Initialization & Reset Utility
# ==============================================================================

export HOME=/config
KASM_USER="${KASM_USER:-brave}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
KASMPASSWD_FILE="/config/kasmvnc/.kasmpasswd"

mkdir -p /config/kasmvnc /config/.vnc 2>/dev/null || true
ln -snf "${KASMPASSWD_FILE}" /config/.kasmpasswd 2>/dev/null || true

ARG="$1"

if [ -z "${ARG}" ] || [ "${ARG}" = "--generate" ]; then
    PASSWORD="$(openssl rand -base64 12)"
    GENERATED=true
else
    PASSWORD="${ARG}"
    GENERATED=false
fi

# Clean temporary default user credentials before creating new user password
rm -f "/config/.kasmpasswd" "${KASMPASSWD_FILE}" 2>/dev/null || true

# Configure KasmVNC credentials representation as braveuser
if [ "$(id -u)" = "0" ]; then
    printf "%s\n%s\nn\n" "${PASSWORD}" "${PASSWORD}" | \
        gosu braveuser kasmvncpasswd -u "${KASM_USER}" -wo >/dev/null 2>&1
else
    printf "%s\n%s\nn\n" "${PASSWORD}" "${PASSWORD}" | \
        kasmvncpasswd -u "${KASM_USER}" -wo >/dev/null 2>&1
fi

if [ -s "/config/.kasmpasswd" ]; then
    cp -f "/config/.kasmpasswd" "${KASMPASSWD_FILE}" 2>/dev/null || true
fi
if [ -s "${KASMPASSWD_FILE}" ]; then
    cp -f "${KASMPASSWD_FILE}" "/config/.kasmpasswd" 2>/dev/null || true
fi

chmod 600 "${KASMPASSWD_FILE}" "/config/.kasmpasswd" 2>/dev/null || true
chown -R "${PUID}:${PGID}" /config/kasmvnc /config/.vnc /config/.kasmpasswd "${KASMPASSWD_FILE}" 2>/dev/null || true

echo "================================================================================"
echo "[kasmvnc] Credentials configured for user '${KASM_USER}'"
if [ "${GENERATED}" = "true" ]; then
    echo " Generated Password: ${PASSWORD}"
    echo ""
    echo " NOTICE: This password will NOT be displayed in container logs."
    echo " Store it securely. To change it later, run:"
    echo "   docker compose exec brave-origin /usr/local/bin/reset-password.sh <new_password>"
else
    echo " Password successfully updated to user-provided value."
fi
echo "================================================================================"
