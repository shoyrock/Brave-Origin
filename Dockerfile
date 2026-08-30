# syntax=docker/dockerfile:1
FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie AS selkies-upstream

# Pinned Selkies Source & Web Dashboard Build at exact commit 92dea42fc70bfcb52e6d98c4e6854872badfe621
FROM node:20-bookworm-slim AS selkies-build
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates python3 patch && \
    git clone https://github.com/selkies-project/selkies.git /selkies-src && \
    cd /selkies-src && \
    git checkout 92dea42fc70bfcb52e6d98c4e6854872badfe621
COPY patches /selkies-src/patches
RUN cd /selkies-src && \
    for p in patches/*.patch; do [ -f "$p" ] && patch -p1 < "$p"; done && \
    cd /selkies-src/addons/selkies-web-core && \
    npm install && \
    npm run build && \
    cd /selkies-src/addons/selkies-dashboard && \
    npm install && \
    npm run build && \
    rm -rf /selkies-src/.git /selkies-src/patches

FROM debian:trixie-slim

LABEL maintainer="shoy" \
      description="Brave Origin Native Wayland Appliance with Selkies, Pixelflux, and Labwc" \
      version="1.93.136"

ENV DEBIAN_FRONTEND=noninteractive \
    PUID=1000 \
    PGID=1000 \
    UMASK=022 \
    TZ=Etc/UTC \
    AUTO_UPDATE=true \
    ENABLE_AUDIO=true \
    AUTH_ENABLED=false \
    PIXELFLUX_WAYLAND=true \
    SELKIES_ENABLE_BASIC_AUTH=false \
    SELKIES_ENABLE_DUAL_MODE=false \
    SELKIES_PORT=8082 \
    CUSTOM_WS_PORT=8082 \
    SELKIES_ADDR=127.0.0.1 \
    XDG_RUNTIME_DIR=/tmp/runtime-braveuser \
    WAYLAND_DISPLAY=wayland-1 \
    PULSE_SERVER=unix:/tmp/runtime-braveuser/pulse/native

# 1. Add Official Brave Origin Apt Repository (Release Channel)
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl gnupg && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    -o /etc/apt/keyrings/brave-browser-archive-keyring.gpg && \
    chmod 644 /etc/apt/keyrings/brave-browser-archive-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list && \
    rm -rf /var/lib/apt/lists/*

# 2. Base Utilities, Wayland Compositor, Audio, Graphics, Python & Brave Origin
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    procps \
    iproute2 \
    openssl \
    nginx \
    apache2-utils \
    pulseaudio \
    pulseaudio-utils \
    dbus \
    labwc \
    libwlroots-0.18 \
    wtype \
    wl-clipboard \
    wayland-protocols \
    libwayland-client0 \
    libwayland-server0 \
    libwayland-cursor0 \
    libwayland-egl1 \
    libdrm2 \
    libdrm-intel1 \
    libdrm-amdgpu1 \
    libdrm-radeon1 \
    libdrm-nouveau2 \
    libgbm1 \
    libpixman-1-0 \
    libcairo2 \
    libcairo-gobject2 \
    libpango-1.0-0 \
    libpangocairo-1.0-0 \
    libgl1-mesa-dri \
    libglx-mesa0 \
    libegl1 \
    libgles2 \
    mesa-vulkan-drivers \
    mesa-va-drivers \
    intel-media-va-driver \
    libva2 \
    libva-drm2 \
    libva-wayland2 \
    python3 \
    python3-pip \
    python3-pil \
    python3-websockets \
    python3-aiohttp \
    python3-aiofiles \
    python3-msgpack \
    fonts-liberation \
    fonts-dejavu-core \
    fonts-noto-color-emoji \
    xdg-utils \
    desktop-file-utils \
    shared-mime-info \
    hicolor-icon-theme \
    libnss3 \
    libatk1.0-0t64 \
    libatk-bridge2.0-0t64 \
    libcups2t64 \
    libxcomposite1 \
    libxdamage1 \
    libxfixes3 \
    libxrandr2 \
    libasound2t64 \
    brave-origin \
    && rm -rf /var/lib/apt/lists/*

# 3. Ingest Pinned Upstream Pixelflux and pcmflux from LinuxServer, and Selkies Backend + Dashboard from 92dea42f
COPY --from=selkies-upstream /lsiopy/lib/python3.13/site-packages/ /usr/local/lib/python3.13/dist-packages/
COPY --from=selkies-upstream /usr/bin/selkies-desktop /usr/local/bin/selkies-desktop
COPY --from=selkies-upstream /usr/bin/wtype /usr/local/bin/wtype
# Install matching Selkies Python backend and web dashboard built at 92dea42f
COPY --from=selkies-build /selkies-src /tmp/selkies-src
RUN pip install --no-deps /tmp/selkies-src --break-system-packages && \
    mkdir -p /usr/share/selkies/web && \
    cp -r /tmp/selkies-src/addons/selkies-dashboard/dist/* /usr/share/selkies/web/ && \
    rm -rf /tmp/selkies-src /root/.cache

# 4. Create Unprivileged Non-Root User (braveuser)
RUN groupadd -r render 2>/dev/null || true && \
    groupadd -g 1000 braveuser && \
    useradd -u 1000 -g braveuser -G audio,video,render -m -s /bin/bash braveuser && \
    mkdir -p /config /tmp/runtime-braveuser /tmp/brave-cache /etc/nginx/ssl /usr/share/selkies/web && \
    chmod 700 /tmp/runtime-braveuser && \
    chown -R braveuser:braveuser /config /tmp/runtime-braveuser /tmp/brave-cache

# 5. Copy Configuration and Session Scripts
COPY config/nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/start-session.sh /usr/local/bin/start-session.sh
COPY scripts/update-brave.sh /usr/local/bin/update-brave.sh
COPY scripts/profile-control.sh /usr/local/bin/profile-control.sh
COPY scripts/reset-password.sh /usr/local/bin/reset-password.sh

ARG BUILD_COMMIT=dev
RUN echo "${BUILD_COMMIT}" > /etc/brave-origin-build

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/start-session.sh \
             /usr/local/bin/update-brave.sh \
             /usr/local/bin/profile-control.sh \
             /usr/local/bin/reset-password.sh

VOLUME ["/config"]
EXPOSE 8443

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
