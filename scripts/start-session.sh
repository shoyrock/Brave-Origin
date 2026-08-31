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

# Clean up stale session processes left over from a crashed or updated session.
# Without this, the relaunched Selkies server cannot rebind 127.0.0.1:8082.
STALE_CLEANED=0
pkill -TERM -f "python3 -m selkies" 2>/dev/null && STALE_CLEANED=1 || true
pkill -TERM -x labwc 2>/dev/null && STALE_CLEANED=1 || true
pkill -TERM -f "/opt/brave.com/brave-origin/brave" 2>/dev/null && STALE_CLEANED=1 || true
if [ "${STALE_CLEANED}" = "1" ]; then
    sleep 1
    pkill -KILL -f "python3 -m selkies" 2>/dev/null || true
    pkill -KILL -x labwc 2>/dev/null || true
fi

# Helper function to check UNIX domain socket connectivity
check_socket_ready() {
    local socket_path="$1"
    python3 -c "import socket; s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(0.5); s.connect('${socket_path}'); s.close()" 2>/dev/null
}

# 1. Start D-Bus Session Daemon
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    mkdir -p "${XDG_RUNTIME_DIR}/dbus"
    dbus-daemon --session --fork --address="unix:path=${XDG_RUNTIME_DIR}/dbus/session_bus_socket"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${XDG_RUNTIME_DIR}/dbus/session_bus_socket"
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

# 3. Start Selkies Streaming Server (Smithay Wayland Display on 127.0.0.1:8082)
echo "[start-session] Starting Selkies Wayland display & streaming server on 127.0.0.1:8082..."
export SELKIES_AUDIO_ENABLED="${AUDIO_ENABLED}"
export SELKIES_AUDIO_DEVICE_NAME="output.monitor"
export SELKIES_ENABLE_BASIC_AUTH=false
export SELKIES_ENABLE_DUAL_MODE=false
export SELKIES_PORT=8082
export CUSTOM_WS_PORT=8082

python3 -m selkies \
    --addr=127.0.0.1 \
    --port=8082 \
    --mode=websockets \
    --wayland=true \
    --app-wayland-display=wayland-0 \
    --enable-basic-auth=false \
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
            if check_socket_ready "${s}"; then
                SMITHAY_SOCKET="${s}"
                export SMITHAY_DISPLAY="$(basename "${s}")"
                export WAYLAND_DISPLAY="${SMITHAY_DISPLAY}"
                break
            fi
        fi
    done
    [ -n "${SMITHAY_SOCKET}" ] && break
    sleep 0.2
    ELAPSED=$((ELAPSED + 1))
    if [ "${ELAPSED}" -ge "$((TIMEOUT * 5))" ]; then
        echo "[start-session] ERROR: Timeout waiting for root Wayland socket in ${XDG_RUNTIME_DIR}!" >&2
        cat /config/state/selkies.log >&2 || true
        exit 1
    fi
done
echo "[start-session] Root Wayland display ready: ${SMITHAY_SOCKET} (WAYLAND_DISPLAY=${WAYLAND_DISPLAY})"

# 5. Start Labwc Wayland Window Manager on root display
echo "[start-session] Starting Labwc window manager on root display ${WAYLAND_DISPLAY}..."
mkdir -p /config/.config/labwc
# Kiosk lockdown: the canonical rc.xml is rewritten on every start so a
# persisted config can never re-enable window management or desktop access.
#
# Decorations strategy: the compositor claims server-side decorations for
# every window (serverDecoration="yes" at first map), which stops Brave from
# drawing its own client-side close/minimize/maximize buttons in the tab
# strip. Labwc's own titlebar is rendered inert: an empty button layout, no
# window title text, and zero-height padding via the kiosk themerc, so the
# server decoration exists but offers no window operations.
cat << 'EOF' > /config/.config/labwc/rc.xml
<?xml version="1.0"?>
<labwc_config>
  <theme>
    <name>kiosk</name>
    <cornerRadius>4</cornerRadius>
    <titlebar>
      <layout>:</layout>
      <showTitle>no</showTitle>
    </titlebar>
    <font place="ActiveWindow">
      <name>sans</name>
      <size>1</size>
    </font>
    <font place="InactiveWindow">
      <name>sans</name>
      <size>1</size>
    </font>
  </theme>
  <!-- Kiosk appliance policy: the browser UI (tabs, address bar, bookmarks)
       stays visible, but the window is always maximized and cannot be
       closed, minimized, resized, or moved. -->
  <windowRules>
    <windowRule identifier="*" serverDecoration="yes">
      <action name="Maximize" />
    </windowRule>
  </windowRules>
  <!-- No default keyboard bindings: window switching, closing, and
       un-maximization are unavailable. Swallow the escape hatches
       (quit, close window/tab, fullscreen toggle). -->
  <keyboard>
    <keybind key="C-q"><action name="None" /></keybind>
    <keybind key="C-S-q"><action name="None" /></keybind>
    <keybind key="C-w"><action name="None" /></keybind>
    <keybind key="C-S-w"><action name="None" /></keybind>
    <keybind key="A-F4"><action name="None" /></keybind>
    <keybind key="F11"><action name="None" /></keybind>
    <keybind key="A-Tab"><action name="None" /></keybind>
    <keybind key="S-A-Tab"><action name="None" /></keybind>
    <keybind key="A-F10"><action name="None" /></keybind>
  </keyboard>
  <!-- Titlebar gestures are inert: no move/drag or maximize toggle. -->
  <mouse>
    <context name="TitleBar">
      <mousebind button="Left" action="Click"><action name="None" /></mousebind>
      <mousebind button="Left" action="DoubleClick"><action name="None" /></mousebind>
      <mousebind button="Middle" action="DoubleClick"><action name="None" /></mousebind>
    </context>
  </mouse>
</labwc_config>
EOF

# Kiosk themerc (correct labwc search path: themes/<name>/labwc/). Zero
# padding and borders collapse the inert server-side titlebar to nothing.
for THEME_DIR in "${HOME}/.local/share/themes/kiosk/labwc" "${HOME}/.themes/kiosk/labwc"; do
    mkdir -p "${THEME_DIR}"
    cat << 'EOF' > "${THEME_DIR}/labwc-themerc"
# Kiosk theme: the server-side titlebar occupies no visible space
window.titlebar.padding.width: 0
window.titlebar.padding.height: 0
window.button.width: 1
window.button.height: 1
border.width: 0
padding.height: 0
EOF
done

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
            if check_socket_ready "${s}"; then
                LABWC_SOCKET="${s}"
                export LABWC_DISPLAY="$(basename "${s}")"
                break
            fi
        fi
    done
    [ -n "${LABWC_SOCKET}" ] && break
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

# 6. GPU Detection & Flags Configuration (ENABLE_GPU=false forces software rendering)
GPU_FLAGS=""
if [ "${ENABLE_GPU:-true}" = "false" ]; then
    echo "[start-session] ENABLE_GPU=false - forcing software rasterization"
elif [ -e "/dev/dri/renderD128" ]; then
    echo "[start-session] GPU /dev/dri/renderD128 detected - enabling hardware acceleration"
    export LIBVA_DRIVER_NAME_OVERRIDE=""
    GPU_FLAGS="--enable-gpu-rasterization --enable-zero-copy --ignore-gpu-blocklist --disable-features=Vulkan"
else
    echo "[start-session] No /dev/dri GPU device detected - running with software rasterization"
fi
if [ -z "${GPU_FLAGS}" ]; then
    GPU_FLAGS="--disable-gpu --disable-gpu-compositing"
fi

# 7. Launch Brave Origin Natively on Wayland (Direct Process Execution)
echo "[start-session] Starting Brave Origin with native Wayland Ozone backend..."

# Serialize with any in-flight update transaction (update-brave.sh Stage 2
# offline install) so Brave is not exec'd while its own files are replaced.
ELAPSED=0
while [ -f /tmp/brave-update-in-progress ]; do
    if [ "${ELAPSED}" -eq 0 ]; then
        echo "[start-session] Waiting for in-flight browser update to complete..."
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
    if [ "${ELAPSED}" -ge 120 ]; then
        echo "[start-session] Warning: update transaction still active after 120s - launching anyway." >&2
        break
    fi
done

# Acquire the authoritative profile lock (exclusive, non-blocking). It is taken
# here - after the session daemons started - so only the Brave process tree
# inherits the lock fd; it survives `exec` and the kernel releases it when the
# browser dies. This prevents concurrent instances on the same /config profile.
exec 9>"/config/state/profile.lock"
if ! flock -n 9; then
    echo "[start-session] ERROR: /config/state/profile.lock is held by another Brave Origin instance on this profile!" >&2
    exit 1
fi

# Safe singleton recovery: clear stale Chromium artifacts only after the flock
rm -f /config/profile/Singleton* 2>/dev/null || true

# Skip Brave Origin's one-time welcome modal on fresh profiles: it takes over
# the whole window and hides the browser chrome until dismissed. Seeding the
# dismissal pref before first launch makes a brand-new /config start directly
# in the usable browser.
if [ ! -f "/config/profile/Local State" ]; then
    printf '%s\n' '{"brave":{"has_seen_brave_welcome_page":true}}' > "/config/profile/Local State"
fi

# Window-button lockdown: force Chromium to use the compositor's (inert,
# buttonless) server-side titlebar instead of drawing its own close/minimize/
# maximize buttons inside the tab strip. Applied to fresh profiles via the
# seed below and re-asserted on every start for existing profiles.
if [ ! -f "/config/profile/Default/Preferences" ]; then
    mkdir -p /config/profile/Default
    printf '%s\n' '{"browser":{"custom_chrome_frame":false}}' > "/config/profile/Default/Preferences"
else
    python3 - << 'EOF'
import json
p = "/config/profile/Default/Preferences"
try:
    with open(p) as f:
        d = json.load(f)
    if d.get("browser", {}).get("custom_chrome_frame") is not False:
        d.setdefault("browser", {})["custom_chrome_frame"] = False
        with open(p, "w") as f:
            json.dump(d, f)
except Exception:
    pass
EOF
fi

# Record PID for update-brave.sh Stage 2 and profile-control.sh quiesce/resume
echo $$ > /tmp/brave.pid
# Record the version about to use this profile (atomic write, 0600) so that
# update-brave.sh downgrade protection compares against a real launch version
USED_VER="$(dpkg-query -W -f='${Version}' brave-origin 2>/dev/null || echo "unknown")"
printf '%s\n' "${USED_VER}" > "/config/state/.last-brave-version.tmp.$$"
chmod 600 "/config/state/.last-brave-version.tmp.$$"
mv -f "/config/state/.last-brave-version.tmp.$$" "/config/state/last-brave-version"
exec /opt/brave.com/brave-origin/brave \
    --ozone-platform=wayland \
    --enable-features=UseOzonePlatform,ShowWindowTitleBar \
    --user-data-dir=/config/profile \
    --disk-cache-dir=/tmp/brave-cache \
    --default-download-directory=/config/downloads \
    --no-first-run \
    --no-default-browser-check \
    --password-store=basic \
    --start-maximized \
    ${GPU_FLAGS} \
    ${BRAVE_FLAGS:-} \
    "$@" >> /config/state/brave.log 2>&1
