#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# Web Authentication Password Initialization & Reset Utility
# ==============================================================================

AUTH_USER="${AUTH_USER:-${KASM_USER:-brave}}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
PASSWD_FILE="/config/.passwd"

ARG="$1"

if [ -z "${ARG}" ] || [ "${ARG}" = "--generate" ]; then
    PASSWORD="$(openssl rand -base64 12)"
    GENERATED=true
else
    PASSWORD="${ARG}"
    GENERATED=false
fi

# Clean existing credentials file before creating new password
rm -f "${PASSWD_FILE}" /config/.kasmpasswd 2>/dev/null || true

# Configure credentials via htpasswd
htpasswd -bc "${PASSWD_FILE}" "${AUTH_USER}" "${PASSWORD}" >/dev/null 2>&1
chmod 644 "${PASSWD_FILE}" 2>/dev/null || true
chown "${PUID}:${PGID}" "${PASSWD_FILE}" 2>/dev/null || true

# Reload Nginx if running
if pgrep -x nginx >/dev/null 2>&1; then
    nginx -s reload 2>/dev/null || true
fi

echo "================================================================================"
echo "[auth] Credentials configured for user '${AUTH_USER}'"
if [ "${GENERATED}" = "true" ]; then
    echo " Generated Password: ${PASSWORD}"
    echo ""
    echo " NOTICE: This password will NOT be displayed in container logs."
    echo " Store it securely. To change it later, run:"
    echo "   docker exec Brave-Origin /usr/local/bin/reset-password.sh <new_password>"
else
    echo " Password successfully updated to user-provided value."
fi
echo "================================================================================"

