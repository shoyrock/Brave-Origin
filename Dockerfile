# syntax=docker/dockerfile:1
FROM ghcr.io/linuxserver/baseimage-selkies:debiantrixie@sha256:7f4f69e5184e3e1876e96ca0c5d66bc3ef5ffe3d47a910cbf6366fe59db3e972 AS selkies-upstream

# Pinned Selkies Source & Web Dashboard Build at exact commit 92dea42fc70bfcb52e6d98c4e6854872badfe621
FROM node:22-trixie-slim AS selkies-build
RUN apt-get update && apt-get install -y --no-install-recommends patch && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:9065cea8eeea43942f1ac513a92b51d669031a4a4ec9907356471eff14e05d4a \
    https://codeload.github.com/selkies-project/selkies/tar.gz/92dea42fc70bfcb52e6d98c4e6854872badfe621 /tmp/selkies.tar.gz
RUN mkdir /selkies-src && tar -xzf /tmp/selkies.tar.gz -C /selkies-src --strip-components=1 && rm /tmp/selkies.tar.gz
COPY patches/*.patch /selkies-src/patches/
COPY dependencies/selkies-web-core.package-lock.json /selkies-src/addons/selkies-web-core/package-lock.json
COPY dependencies/selkies-dashboard.package-lock.json /selkies-src/addons/selkies-dashboard/package-lock.json
COPY tests/client-clipboard.mjs /tmp/client-clipboard.mjs
COPY tests/client-audio.mjs /tmp/client-audio.mjs
RUN cd /selkies-src && \
    for p in patches/*.patch; do [ -f "$p" ] && patch -p1 < "$p"; done && \
    node /tmp/client-clipboard.mjs /selkies-src/addons/selkies-web-core/lib/clipboard-sync.js && \
    node /tmp/client-audio.mjs /selkies-src/addons/selkies-web-core/selkies-ws-core.js && \
    cd /selkies-src/addons/selkies-web-core && \
    npm ci && \
    npm run build && \
    cd /selkies-src/addons/selkies-dashboard && \
    npm ci && \
    npm run build && \
    mkdir /selkies-package && \
    cp /selkies-src/pyproject.toml /selkies-src/README.md /selkies-src/LICENSE /selkies-package/ && \
    cp -r /selkies-src/src /selkies-package/ && \
    rm -rf /selkies-src/.git /selkies-src/patches

# Build both window managers from the same pinned source; Brave remains the official,
# unmodified package. Debian's labwc package is not used because it depends on Xwayland.
FROM debian:trixie-slim AS labwc-build
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential meson ninja-build pkg-config patch xz-utils ca-certificates \
    libwlroots-0.18-dev libxml2-dev libglib2.0-dev libcairo2-dev \
    libpango1.0-dev libpng-dev librsvg2-dev libcmocka-dev wayland-protocols \
    && rm -rf /var/lib/apt/lists/*
ADD --checksum=sha256:746be2ff2d0c0c0b795c97fa24c7058f75586685c88a1194c243b6a846f938a5 \
    https://codeload.github.com/labwc/labwc/tar.gz/refs/tags/0.8.3 /tmp/labwc.tar.gz
RUN mkdir /labwc && tar -xzf /tmp/labwc.tar.gz -C /labwc --strip-components=1 && rm /tmp/labwc.tar.gz
COPY patches/labwc/lock-maximized.patch /tmp/lock-maximized.patch
COPY patches/labwc/README.md /labwc/BRAVE-ORIGIN-CHANGES.md
COPY Dockerfile /labwc/Brave-Origin.Dockerfile
# Stock binary first (BROWSER_LOCK_MAXIMIZED=false), then the maximization policy.
RUN cd /labwc && \
    set -- --buildtype=release --wrap-mode=nofallback \
        -Dxwayland=disabled -Dicon=disabled -Dman-pages=disabled -Dtest=enabled \
        -Db_pie=true -Db_lto=true -Dc_args='-fstack-protector-strong -D_FORTIFY_SOURCE=3' \
        -Dc_link_args='-Wl,-z,relro,-z,now' && \
    meson setup /labwc-stock-build "$@" && \
    meson compile -C /labwc-stock-build -j 2 && meson test -C /labwc-stock-build --print-errorlogs && \
    strip /labwc-stock-build/labwc && \
    cp /tmp/lock-maximized.patch /labwc/BRAVE-ORIGIN-lock-maximized.patch && \
    patch -p1 < /tmp/lock-maximized.patch && \
    meson setup /labwc-build "$@" && \
    meson compile -C /labwc-build -j 2 && meson test -C /labwc-build --print-errorlogs && \
    strip /labwc-build/labwc && tar -cJf /labwc-source.tar.xz -C / labwc

FROM debian:trixie-slim


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
# apt verifies signatures with sqv; gnupg is not needed to install a binary keyring.
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl && \
    install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg \
    -o /etc/apt/keyrings/brave-browser-archive-keyring.gpg && \
    chmod 644 /etc/apt/keyrings/brave-browser-archive-keyring.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/brave-browser-archive-keyring.gpg arch=amd64] https://brave-browser-apt-release.s3.brave.com/ stable main" \
    > /etc/apt/sources.list.d/brave-browser-release.list && \
    rm -rf /var/lib/apt/lists/*

# 2. Base Utilities, Wayland Compositor, Audio, Graphics, Python & Brave Origin
# Apply pending Debian security updates to the base image before adding packages.
RUN apt-get update && apt-get upgrade -y --no-install-recommends && apt-get install -y --no-install-recommends \
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
    libwlroots-0.18 \
    libglib2.0-0t64 \
    libpng16-16t64 \
    librsvg2-2 \
    libxml2 \
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

RUN apt-get update && apt-get install -y --no-install-recommends tini tzdata util-linux && rm -rf /var/lib/apt/lists/*

# 2.5 Brave managed policy: bookmarks bar always visible in the locked session
RUN mkdir -p /etc/brave/policies/managed && \
    printf '%s\n' '{"BookmarkBarEnabled": true, "DownloadDirectory": "/config/downloads"}' > /etc/brave/policies/managed/policies.json && \
    chmod 644 /etc/brave/policies/managed/policies.json

# 3. Ingest pinned upstream Pixelflux and pcmflux from LinuxServer, and Selkies Backend + Dashboard from 92dea42f
COPY --from=selkies-upstream /lsiopy/lib/python3.13/site-packages/ /usr/local/lib/python3.13/dist-packages/
COPY --from=selkies-upstream /usr/bin/wtype /usr/local/bin/wtype
COPY dependencies/runtime.txt /tmp/runtime-requirements.txt
# Pelorus is the donor desktop's launcher; it is not used by this browser image.
RUN rm -rf /usr/local/lib/python3.13/dist-packages/pelorus /usr/local/lib/python3.13/dist-packages/pelorus-*.dist-info && \
    pip install --break-system-packages --no-cache-dir --no-deps --require-hashes -r /tmp/runtime-requirements.txt && \
    rm /tmp/runtime-requirements.txt
# Install matching Selkies Python backend and web dashboard built at 92dea42f
COPY --from=selkies-build /selkies-package /tmp/selkies-src
COPY --from=selkies-build /selkies-src/addons/selkies-dashboard/dist/ /usr/share/selkies/web/
RUN pip install --no-deps --no-build-isolation /tmp/selkies-src --break-system-packages && \
    mkdir -p /usr/share/selkies/web && \
    cp /opt/brave.com/brave-origin/product_logo_256.png /usr/share/selkies/web/icon.png && \
    cp /opt/brave.com/brave-origin/product_logo_256.png /usr/share/selkies/web/icon-512.png && \
    grep -rl "Selkies" /usr/share/selkies/web/index.html /usr/share/selkies/web/assets/ /usr/share/selkies/web/manifest.json 2>/dev/null | \
        xargs -r sed -i 's/Selkies/Brave Origin/g' && \
    rm -rf /tmp/selkies-src /root/.cache && \
    python3 -m pip check

# 4. Create Unprivileged Non-Root User (braveuser)
RUN groupadd -r render 2>/dev/null || true && \
    groupadd -g 1000 braveuser && \
    useradd -u 1000 -g braveuser -G audio,video,render -m -s /bin/bash braveuser && \
    mkdir -p /config /tmp/runtime-braveuser /tmp/brave-cache /etc/nginx/ssl /usr/share/selkies/web && \
    chmod 700 /tmp/runtime-braveuser && \
    chown -R braveuser:braveuser /config /tmp/runtime-braveuser /tmp/brave-cache

# 4.5 Nothing in this image escalates through setuid programs or file capabilities.
# Brave's own sandbox helper is kept so the browser still starts on hosts without
# unprivileged user namespaces; no-new-privileges neutralizes it where set.
RUN find / -xdev -type f -perm /6000 ! -path /opt/brave.com/brave-origin/chrome-sandbox -exec chmod a-s {} + && \
    getcap -r / 2>/dev/null | cut -d' ' -f1 | xargs -r -n1 setcap -r

# 5. Copy Configuration and Session Scripts
COPY --from=labwc-build /labwc-build/labwc /usr/local/bin/labwc-browser
COPY --from=labwc-build /labwc-stock-build/labwc /usr/local/bin/labwc
# Corresponding GPL source accompanies the modified compositor binary.
COPY --from=labwc-build /labwc-source.tar.xz /usr/local/share/brave-origin/labwc-source.tar.xz
COPY config/nginx.conf /etc/nginx/nginx.conf
COPY scripts/prepare-storage.py /usr/local/bin/prepare-storage.py
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/start-session.sh /usr/local/bin/start-session.sh
COPY scripts/update-brave.sh /usr/local/bin/update-brave.sh
COPY scripts/profile-control.sh /usr/local/bin/profile-control.sh
COPY scripts/reset-password.sh /usr/local/bin/reset-password.sh

# Keep release metadata after dependency installation to reuse build layers.
ARG VERSION=1.0.0-beta.1
ARG BUILD_COMMIT=dev
LABEL org.opencontainers.image.title="Brave Origin" \
      org.opencontainers.image.description="Brave Origin browser with remote HTTPS access" \
      org.opencontainers.image.source="https://github.com/shoyrock/Brave-Origin" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${BUILD_COMMIT}"

# Entrypoint supplies the secure default while honoring legacy auth variables.
ENV AUTH_ENABLED=""
RUN echo "${BUILD_COMMIT}" > /etc/brave-origin-build

RUN chmod +x /usr/local/bin/entrypoint.sh \
             /usr/local/bin/start-session.sh \
             /usr/local/bin/update-brave.sh \
             /usr/local/bin/profile-control.sh \
             /usr/local/bin/reset-password.sh

VOLUME ["/config"]
EXPOSE 8443
COPY scripts/healthcheck.sh /usr/local/bin/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=10s --start-period=60s --retries=3 CMD ["bash", "/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
