#!/usr/bin/env bash
set -eo pipefail

# ==============================================================================
# KasmVNC Password Initialization & Reset Utility
# ==============================================================================

KASM_USER="${KASM_USER:-brave}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
KASMPASSWD_FILE="/config/kasmvnc/.kasmpasswd"

mkdir -p /config/kasmvnc 2>/dev/null || true

ARG="$1"

if [ -z "${ARG}" ] || [ "${ARG}" = "--generate" ]; then
    PASSWORD="$(openssl rand -base64 12)"
    GENERATED=true
else
    PASSWORD="${ARG}"
    GENERATED=false
fi

# Configure KasmVNC credentials representation
printf "%s\n%s\n" "${PASSWORD}" "${PASSWORD}" | \
    kasmvncpasswd -u "${KASM_USER}" -wo "${KASMPASSWD_FILE}" >/dev/null 2>&1

chmod 600 "${KASMPASSWD_FILE}" 2>/dev/null || true
chown -R "${PUID}:${PGID}" /config/kasmvnc 2>/dev/null || true

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
