# syntax=docker/dockerfile:1
FROM debian:trixie-slim

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=C.UTF-8 \
    DISPLAY=:1 \
    HOME=/config

# Build arguments
ARG BRAVE_ORIGIN_VERSION=""
ARG KASMVNC_VERSION="1.5.0"

# 1. Install prerequisites, desktop dependencies, and fonts
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        gosu \
        tini \
        procps \
        openssl \
        ssl-cert \
        xdg-utils \
        openbox \
        nginx-light \
        dbus-x11 \
        pulseaudio \
        pulseaudio-utils \
        libasound2 \
        libasound2-plugins \
        fonts-liberation \
        fonts-dejavu-core \
        fonts-noto-color-emoji \
        xauth \
        x11-utils \
        x11-xkb-utils \
        xkb-data \
        libswitch-perl \
        libyaml-tiny-perl \
        libhash-merge-simple-perl \
        libdatetime-perl \
        libdatetime-timezone-perl \
        libtry-tiny-perl \
    ; \
    # 2. Add official Brave APT repository
    curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
        https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg; \
    curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
        https://brave-browser-apt-release.s3.brave.com/brave-browser.sources; \
    apt-get update; \
    if [ -n "${BRAVE_ORIGIN_VERSION}" ] && [ "${BRAVE_ORIGIN_VERSION}" != "latest" ]; then \
        apt-get install -y --no-install-recommends "brave-origin=${BRAVE_ORIGIN_VERSION}"; \
    else \
        apt-get install -y --no-install-recommends brave-origin; \
    fi; \
    if [ -f /opt/brave.com/brave-origin/chrome-sandbox ]; then \
        chown root:root /opt/brave.com/brave-origin/chrome-sandbox; \
        chmod 4755 /opt/brave.com/brave-origin/chrome-sandbox; \
    fi; \
    if [ -f /opt/brave.com/brave-origin/apparmor.d/brave-origin-stable ]; then \
        mkdir -p /etc/apparmor.d; \
        cp /opt/brave.com/brave-origin/apparmor.d/brave-origin-stable /etc/apparmor.d/brave-origin; \
    fi; \
    # 3. Download, validate, and install verified official KasmVNC release asset for Debian Trixie
    ARCH="$(dpkg --print-architecture)"; \
    KASMVNC_DEB="kasmvncserver_trixie_${KASMVNC_VERSION}_${ARCH}.deb"; \
    KASMVNC_URL="https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/${KASMVNC_DEB}"; \
    echo "Downloading verified KasmVNC release asset from: ${KASMVNC_URL}"; \
    if ! curl -fsSL -o /tmp/kasmvnc.deb "${KASMVNC_URL}"; then \
        echo "ERROR: Failed to download official KasmVNC release asset '${KASMVNC_DEB}' for architecture '${ARCH}' from '${KASMVNC_URL}'!" >&2; \
        exit 1; \
    fi; \
    if [ ! -s /tmp/kasmvnc.deb ]; then \
        echo "ERROR: Downloaded KasmVNC file is empty (0 bytes)!" >&2; \
        exit 1; \
    fi; \
    # Validate package integrity and metadata using dpkg-deb
    if ! dpkg-deb -I /tmp/kasmvnc.deb >/dev/null 2>&1; then \
        echo "ERROR: Downloaded file is not a valid Debian package archive!" >&2; \
        exit 1; \
    fi; \
    PKG_NAME="$(dpkg-deb -f /tmp/kasmvnc.deb Package 2>/dev/null || echo "")"; \
    if [ "${PKG_NAME}" != "kasmvncserver" ]; then \
        echo "ERROR: Unexpected package name '${PKG_NAME}' (expected 'kasmvncserver')!" >&2; \
        exit 1; \
    fi; \
    PKG_VER="$(dpkg-deb -f /tmp/kasmvnc.deb Version 2>/dev/null || echo "")"; \
    case "${PKG_VER}" in \
        "${KASMVNC_VERSION}"*) ;; \
        *) \
            echo "ERROR: Package version '${PKG_VER}' does not match expected version '${KASMVNC_VERSION}'!" >&2; \
            exit 1; \
            ;; \
    esac; \
    PKG_ARCH="$(dpkg-deb -f /tmp/kasmvnc.deb Architecture 2>/dev/null || echo "")"; \
    if [ "${PKG_ARCH}" != "${ARCH}" ]; then \
        echo "ERROR: Package architecture '${PKG_ARCH}' does not match target architecture '${ARCH}'!" >&2; \
        exit 1; \
    fi; \
    echo "Successfully validated Debian package: ${PKG_NAME} (${PKG_VER}) [${PKG_ARCH}]"; \
    apt-get install -y --no-install-recommends /tmp/kasmvnc.deb; \
    rm -f /tmp/kasmvnc.deb; \
    # 4. Strict Build-Time Package Verification
    dpkg-query -W -f='${Package} ${Version}\n' brave-origin; \
    if dpkg -s brave-browser 2>/dev/null || dpkg -s brave-browser-beta 2>/dev/null || dpkg -s brave-browser-nightly 2>/dev/null || dpkg -s brave-browser-dev 2>/dev/null; then \
        echo "ERROR: Standard Brave Browser packages detected in image build!" >&2; \
        exit 1; \
    fi; \
    echo "========================================================"; \
    echo " Build Verification Summary:"; \
    echo " Base OS: Debian 13 Trixie Slim"; \
    echo " Browser package: $(dpkg-query -W -f='${Package} (${Version})' brave-origin)"; \
    echo " Browser channel/product: Brave Origin Release"; \
    echo " Standard Brave Browser installed: No"; \
    echo " KasmVNC installed: Yes (${PKG_NAME} ${PKG_VER} [${PKG_ARCH}])"; \
    echo " Persistent directory: /config"; \
    echo "========================================================"; \
    # 5. Clean APT caches to minimize final image size
    apt-get purge -y --auto-remove gnupg; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

# Configure Openbox minimal window management defaults (auto-maximize browser, no terminal menu)
RUN set -eux; \
    mkdir -p /etc/xdg/openbox; \
    cat <<'EOF' > /etc/xdg/openbox/rc.xml
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="*">
      <maximized>yes</maximized>
      <decor>no</decor>
      <focus>yes</focus>
    </application>
  </applications>
  <margins>
    <top>0</top>
    <bottom>0</bottom>
    <left>0</left>
    <right>0</right>
  </margins>
  <resistance>
    <strength>10</strength>
    <screen_edge_strength>20</screen_edge_strength>
  </resistance>
  <focus>
    <focusNew>yes</focusNew>
    <followMouse>no</followMouse>
  </focus>
</openbox_config>
EOF

# Setup standard user, group, and persistent mount points
RUN set -eux; \
    groupadd -g 1000 braveuser; \
    useradd -u 1000 -g braveuser -G ssl-cert -d /config -s /bin/bash -m braveuser; \
    mkdir -p /config/profile \
             /config/downloads \
             /config/kasmvnc/certs \
             /config/state \
             /tmp/brave-cache \
             /tmp/.X11-unix \
             /tmp/runtime-braveuser \
             /run/lock; \
    chmod 1777 /tmp/.X11-unix /run/lock; \
    chmod 700 /tmp/runtime-braveuser /tmp/brave-cache; \
    chown -R braveuser:braveuser /config /tmp/runtime-braveuser /tmp/brave-cache

# Copy configuration and scripts
COPY config/kasmvnc.yaml /etc/kasmvnc/kasmvnc.yaml
COPY config/nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/start-session.sh /usr/local/bin/start-session.sh
COPY scripts/update-brave.sh /usr/local/bin/update-brave.sh
COPY scripts/profile-control.sh /usr/local/bin/profile-control.sh
COPY scripts/reset-password.sh /usr/local/bin/reset-password.sh
COPY scripts/audio-server.py /usr/local/bin/audio-server.py
COPY config/audio-client.js /etc/kasmvnc/audio-client.js

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/start-session.sh \
             /usr/local/bin/update-brave.sh \
             /usr/local/bin/profile-control.sh \
             /usr/local/bin/reset-password.sh \
             /usr/local/bin/audio-server.py

# Default environment configuration
ENV PUID=1000 \
    PGID=1000 \
    UMASK=022 \
    TZ=UTC \
    WEB_PORT=8443 \
    DISPLAY_WIDTH=1920 \
    DISPLAY_HEIGHT=1080 \
    KASM_AUTH_ENABLED=false \
    KASM_USER=brave \
    KASM_PASSWORD="" \
    KASM_PASSWORD_FILE="" \
    AUTO_UPDATE=true \
    UPDATE_INTERVAL=21600 \
    DOWNGRADE_RETRY_INTERVAL=300 \
    MIN_UPDATE_FREE_SPACE_MB=1024 \
    BRAVE_STARTUP_TIMEOUT=15 \
    BRAVE_ORIGIN_VERSION=latest \
    ENABLE_GPU=true \
    ENABLE_AUDIO=true \
    DRI_NODE=/dev/dri/renderD128 \
    BRAVE_FLAGS=""

# Persistent browser profile, downloads, and Kasm configuration volume
VOLUME ["/config"]

# Expose KasmVNC Single-Origin HTTPS Web Client Port
EXPOSE 8443

# Health check to validate KasmVNC HTTPS responsiveness
HEALTHCHECK --interval=30s --timeout=10s --start-period=15s --retries=3 \
    CMD curl -k -fsS "https://127.0.0.1:${WEB_PORT:-8443}/" >/dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
