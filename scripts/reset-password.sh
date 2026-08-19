#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# Web Authentication Password Initialization & Reset Utility
# ==============================================================================

KASM_USER="${KASM_USER:-brave}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
KASMPASSWD_FILE="/config/.kasmpasswd"

ARG="$1"

if [ -z "${ARG}" ] || [ "${ARG}" = "--generate" ]; then
    PASSWORD="$(openssl rand -base64 12)"
    GENERATED=true
else
    PASSWORD="${ARG}"
    GENERATED=false
fi

# Clean temporary default user credentials before creating new user password
rm -f "${KASMPASSWD_FILE}" 2>/dev/null || true

# Configure credentials via htpasswd
htpasswd -bc "${KASMPASSWD_FILE}" "${KASM_USER}" "${PASSWORD}" >/dev/null 2>&1
chmod 644 "${KASMPASSWD_FILE}" 2>/dev/null || true
chown "${PUID}:${PGID}" "${KASMPASSWD_FILE}" 2>/dev/null || true

# Reload Nginx if running
if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s reload 2>/dev/null || true
fi

echo "================================================================================"
echo "[auth] Credentials configured for user '${KASM_USER}'"
if [ "${GENERATED}" = "true" ]; then
    echo " Generated Password: ${PASSWORD}"
    echo ""
    echo " NOTICE: This password will NOT be displayed in container logs."
    echo " Store it securely. To change it later, run:"
    echo "   docker exec Brave-Origin-Wayland /usr/local/bin/reset-password.sh <new_password>"
else
    echo " Password successfully updated to user-provided value."
fi
echo "================================================================================"
