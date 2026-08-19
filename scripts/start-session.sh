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

# 1. Start D-Bus Session Daemon
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    eval $(dbus-launch --sh-syntax)
fi

# 2. Start PulseAudio Virtual Sink (if ENABLE_AUDIO=true)
if [ "${ENABLE_AUDIO:-true}" = "true" ]; then
    echo "[start-session] Initializing PulseAudio virtual sink..."
    pulseaudio --exit-idle-time=-1 --daemonize=true || true
    pactl load-module module-null-sink sink_name=auto_null sink_properties=device.description="Virtual_Null_Output" 2>/dev/null || true
    pactl set-default-sink auto_null 2>/dev/null || true
    export AUDIO_ENABLED=true
else
    export AUDIO_ENABLED=false
fi

# 3. Start Selkies Streaming Server (Smithay Wayland Display)
echo "[start-session] Starting Selkies Wayland display & streaming server on 127.0.0.1:8082..."
export SELKIES_AUDIO_ENABLED="${AUDIO_ENABLED}"
export SELKIES_ENABLE_DUAL_MODE=false
export SELKIES_PORT=8082
export CUSTOM_WS_PORT=8082

python3 -m selkies \
    --mode=websockets \
    > /config/state/selkies.log 2>&1 &
SELKIES_PID=$!
echo "${SELKIES_PID}" > /config/state/selkies.pid

# 4. Wait for Wayland socket to be created by Pixelflux / Smithay
echo "[start-session] Waiting for Wayland display socket in ${XDG_RUNTIME_DIR}..."
TIMEOUT=30
ELAPSED=0
WAYLAND_SOCKET=""
while [ -z "${WAYLAND_SOCKET}" ]; do
    for s in "${XDG_RUNTIME_DIR}"/wayland-*; do
        if [ -S "${s}" ]; then
            WAYLAND_SOCKET="${s}"
            export WAYLAND_DISPLAY="$(basename "${s}")"
            break
        fi
    done
    if [ -n "${WAYLAND_SOCKET}" ]; then
        break
    fi
    sleep 0.2
    ELAPSED=$((ELAPSED + 1))
    if [ "${ELAPSED}" -ge "$((TIMEOUT * 5))" ]; then
        echo "[start-session] ERROR: Timeout waiting for Wayland socket in ${XDG_RUNTIME_DIR}!" >&2
        cat /config/state/selkies.log >&2 || true
        exit 1
    fi
done
echo "[start-session] Wayland socket detected and ready: ${WAYLAND_SOCKET} (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"

# 5. Start Labwc Wayland Window Manager
echo "[start-session] Starting Labwc window manager..."
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
    <windowRule identifier="*" serverDecoration="no" />
  </windowRules>
</labwc_config>
EOF
fi

labwc -c /config/.config/labwc/rc.xml > /config/state/labwc.log 2>&1 &
LABWC_PID=$!
echo "${LABWC_PID}" > /config/state/labwc.pid

sleep 1

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
    --window-position=0,0 \
    --window-size=1920,1080 \
    ${GPU_FLAGS} \
    "$@" 2>&1 | tee -a /config/state/brave.log
