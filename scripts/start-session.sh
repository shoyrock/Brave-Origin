#!/usr/bin/env bash
# ==============================================================================
# Native Wayland Desktop & Brave Origin Session Starter (Selkies + Labwc)
# ==============================================================================
set -e

export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/runtime-braveuser}"
export WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-1}"
export PULSE_SERVER="unix:${XDG_RUNTIME_DIR}/pulse/native"
export PIXELFLUX_WAYLAND=true
export SELKIES_ENABLE_DUAL_MODE=false
export SELKIES_PORT=8082
export CUSTOM_WS_PORT=8082
export SELKIES_ADDR=127.0.0.1
export XCURSOR_THEME=Adwaita
export XCURSOR_SIZE=24
export XKB_DEFAULT_LAYOUT=us
export XKB_DEFAULT_RULES=evdev

# Explicitly UNSET DISPLAY to guarantee zero X11 / Xwayland execution
unset DISPLAY

mkdir -p "${XDG_RUNTIME_DIR}" /config/state /config/downloads /config/profile
chmod 700 "${XDG_RUNTIME_DIR}"
rm -f "${XDG_RUNTIME_DIR}"/wayland-* "${XDG_RUNTIME_DIR}"/pulse/pid 2>/dev/null || true

# 1. Start D-Bus Session Daemon
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval $(dbus-launch --sh-syntax)
fi

# 2. Start PulseAudio Virtual Sink (if ENABLE_AUDIO=true)
if [ "${ENABLE_AUDIO:-true}" = "true" ]; then
    echo "[start-session] Initializing PulseAudio virtual sink..."
    mkdir -p "${XDG_RUNTIME_DIR}/pulse"
    pulseaudio --exit-idle-time=-1 --daemonize=true || true
    pactl load-module module-native-protocol-unix auth-anonymous=1 socket="${XDG_RUNTIME_DIR}/pulse/native" 2>/dev/null || true
    pactl load-module module-null-sink sink_name=output sink_properties=device.description="Default_Audio_Output" 2>/dev/null || true
    pactl set-default-sink output 2>/dev/null || true
    export PULSE_SERVER="unix:${XDG_RUNTIME_DIR}/pulse/native"
    export AUDIO_ENABLED=true
else
    export AUDIO_ENABLED=false
fi

# 3. Start Selkies Streaming Server (Smithay Wayland Display)
echo "[start-session] Starting Selkies Wayland display & streaming server on 127.0.0.1:8082..."
export SELKIES_AUDIO_ENABLED="${AUDIO_ENABLED}"
export SELKIES_AUDIO_DEVICE_NAME="output.monitor"
export SELKIES_ENABLE_DUAL_MODE=false
export SELKIES_PORT=8082
export CUSTOM_WS_PORT=8082

python3 -m selkies \
    --mode=websockets \
    --wayland=true \
    --app-wayland-display=wayland-0 \
    > /config/state/selkies.log 2>&1 &
SELKIES_PID=$!
echo "${SELKIES_PID}" > /config/state/selkies.pid

# 4. Wait for Wayland display socket created by Pixelflux / Smithay AND test connectable
echo "[start-session] Waiting for root Wayland display socket (Smithay) in ${XDG_RUNTIME_DIR}..."
TIMEOUT=30
ELAPSED=0
SMITHAY_SOCKET=""
while [ -z "${SMITHAY_SOCKET}" ]; do
    for s in "${XDG_RUNTIME_DIR}"/wayland-*; do
        if [ -S "${s}" ]; then
            if python3 -c "import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(0.5); s.connect('${s}'); s.close()" 2>/dev/null; then
                SMITHAY_SOCKET="${s}"
                export SMITHAY_DISPLAY="$(basename "${s}")"
                export WAYLAND_DISPLAY="${SMITHAY_DISPLAY}"
                break
            fi
        fi
    done
    if [ -n "${SMITHAY_SOCKET}" ]; then
        break
    fi
    sleep 0.2
    ELAPSED=$((ELAPSED + 1))
    if [ "${ELAPSED}" -ge "$((TIMEOUT * 5))" ]; then
        echo "[start-session] ERROR: Timeout waiting for root Wayland socket in ${XDG_RUNTIME_DIR}!" >&2
        cat /config/state/selkies.log >&2 || true
        exit 1
    fi
done
echo "[start-session] Root Wayland display ready and accepting connections: ${SMITHAY_SOCKET} (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"

# 5. Start Labwc Wayland Window Manager on root display
echo "[start-session] Starting Labwc window manager on root display ${WAYLAND_DISPLAY}..."
mkdir -p /config/.config/labwc
if [ ! -f "/config/.config/labwc/rc.xml" ]; then
    cat << 'EOF' > /config/.config/labwc/rc.xml
<?xml version="1.0"?>
<labwc_config>
  <theme>
    <name>Adwaita</name>
    <cornerRadius>4</cornerRadius>
  </theme>
  <windowRules>
    <windowRule identifier="*" serverDecoration="no">
      <action name="Maximize" />
    </windowRule>
  </windowRules>
</labwc_config>
EOF
else
    if ! grep -q "Maximize" /config/.config/labwc/rc.xml; then
        sed -i '/<windowRule identifier="\*"/a \      <action name="Maximize" />' /config/.config/labwc/rc.xml
    fi
fi

labwc -c /config/.config/labwc/rc.xml > /config/state/labwc.log 2>&1 &
LABWC_PID=$!
echo "${LABWC_PID}" > /config/state/labwc.pid

# Wait for Labwc client-facing Wayland socket (nested compositor socket) AND verify connectable
echo "[start-session] Waiting for Labwc application Wayland socket in ${XDG_RUNTIME_DIR}..."
ELAPSED=0
LABWC_SOCKET=""
while [ -z "${LABWC_SOCKET}" ]; do
    for s in "${XDG_RUNTIME_DIR}"/wayland-*; do
        if [ -S "${s}" ] && [ "${s}" != "${SMITHAY_SOCKET}" ]; then
            if python3 -c "import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(0.5); s.connect('${s}'); s.close()" 2>/dev/null; then
                LABWC_SOCKET="${s}"
                export LABWC_DISPLAY="$(basename "${s}")"
                break
            fi
        fi
    done
    if [ -n "${LABWC_SOCKET}" ]; then
        break
    fi
    sleep 0.2
    ELAPSED=$((ELAPSED + 1))
    if [ "${ELAPSED}" -ge "$((TIMEOUT * 5))" ]; then
        echo "[start-session] ERROR: Labwc application Wayland socket failed to start!" >&2
        cat /config/state/labwc.log >&2 || true
        exit 1
    fi
done

export WAYLAND_DISPLAY="${LABWC_DISPLAY}"
echo "[start-session] Labwc application Wayland socket ready: ${LABWC_SOCKET} (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"

# 6. GPU Detection & Flags Configuration
GPU_FLAGS=""
if [ -e "/dev/dri/renderD128" ]; then
    echo "[start-session] GPU /dev/dri/renderD128 detected - enabling hardware acceleration"
    export LIBVA_DRIVER_NAME_OVERRIDE=""
    GPU_FLAGS="--enable-gpu-rasterization --enable-zero-copy --ignore-gpu-blocklist --disable-features=Vulkan"
else
    echo "[start-session] No /dev/dri GPU device detected - running with software rasterization"
    GPU_FLAGS="--disable-gpu --disable-gpu-compositing"
fi

# 7. Launch Brave Origin Natively on Wayland
echo "[start-session] Starting Brave Origin with native Wayland Ozone backend..."
rm -f /config/profile/Singleton* 2>/dev/null || true
exec /opt/brave.com/brave-origin/brave \
    --ozone-platform=wayland \
    --enable-features=UseOzonePlatform \
    --user-data-dir=/config/profile \
    --disk-cache-dir=/tmp/brave-cache \
    --default-download-directory=/config/downloads \
    --no-first-run \
    --no-default-browser-check \
    --password-store=basic \
    --start-maximized \
    ${GPU_FLAGS} \
    "$@" 2>&1 | tee -a /config/state/brave.log
