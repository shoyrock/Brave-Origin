# syntax=docker/dockerfile:1
FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie AS selkies-upstream

# Pinned Selkies Source at exact commit 92dea42fc70bfcb52e6d98c4e6854872badfe621
FROM debian:trixie-slim AS selkies-src
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && \
    git clone https://github.com/selkies-project/selkies.git /selkies-src && \
    cd /selkies-src && \
    git checkout 92dea42fc70bfcb52e6d98c4e6854872badfe621 && \
    rm -rf .git

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
    PIXELFLUX_WAYLAND=true \
    SELKIES_ENABLE_DUAL_MODE=false \
    SELKIES_PORT=8082 \
    CUSTOM_WS_PORT=8082 \
    SELKIES_ADDR=127.0.0.1 \
    XDG_RUNTIME_DIR=/tmp/runtime-braveuser \
    WAYLAND_DISPLAY=wayland-1 \
    PULSE_SERVER=unix:/tmp/runtime-braveuser/pulse/native \
    KASM_AUTH_ENABLED=false

# 1. Base Utilities, Wayland, Compositor, Audio & Graphics Libraries
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
    procps \
    psmisc \
    net-tools \
    iproute2 \
    openssl \
    nginx \
    apache2-utils \
    pulseaudio \
    pulseaudio-utils \
    dbus \
    dbus-x11 \
    libpam-systemd \
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
    cron \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# 2. Ingest Pinned Upstream Selkies, Pixelflux, pcmflux, and Web Dashboard
COPY --from=selkies-upstream /lsiopy/lib/python3.13/site-packages/ /usr/local/lib/python3.13/dist-packages/
COPY --from=selkies-upstream /usr/bin/selkies-desktop /usr/local/bin/selkies-desktop
COPY --from=selkies-upstream /usr/bin/wtype /usr/local/bin/wtype
COPY --from=selkies-upstream /usr/share/selkies/selkies-dashboard/ /usr/share/selkies/web/
# Install pinned Selkies 92dea42fc70bfcb52e6d98c4e6854872badfe621
COPY --from=selkies-src /selkies-src /tmp/selkies-src
RUN pip install --no-deps /tmp/selkies-src --break-system-packages && rm -rf /tmp/selkies-src

# 3. Add Official Brave Origin Apt Repository (Release Channel)
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    -o /etc/apt/keyrings/brave-browser-archive-keyring.gpg && \
    chmod 644 /etc/apt/keyrings/brave-browser-archive-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends brave-origin && \
    rm -rf /var/lib/apt/lists/*

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
