# Brave Origin in Docker (Native Wayland / Selkies Web Access)

A production-grade, lightweight Docker appliance for **Brave Origin** built on **Debian 13 Trixie Slim** and accessed remotely from any modern web browser via **Native Wayland / Selkies** over HTTPS. Designed for normal Unraid Docker deployment and standard Linux hosts, featuring native Chromium Ozone Wayland rendering, VAAPI hardware acceleration, atomic profile state tracking, application-level profile locking, safe backup quiescing, unprivileged execution, preserved Chromium sandboxing, and two-stage transaction-safe browser updates.

```text
┌─────────────────────────────────────────────────────────────┐
│ Client Device (Firefox / Chrome / Safari / Edge / Mobile)   │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               │ HTTPS / WSS (Port 8443)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ Docker Container (Debian 13 Trixie Slim)                    │
│                                                             │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Nginx TLS Ingress Proxy (Single-Origin Port 8443)       │ │
│ └────────────────────────────┬────────────────────────────┘ │
│                              │ Proxy to 127.0.0.1:8082      │
│                              ▼                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Selkies Streaming Server + Dashboard (WebSockets)       │ │
│ ├────────────────────────────┬────────────────────────────┤ │
│ │ Pixelflux (VAAPI H.264)    │ pcmflux (Opus Audio)       │ │
│ └────────────────────────────┴────────────────────────────┘ │
│                              │                              │
│ ┌────────────────────────────▼────────────────────────────┐ │
│ │ Smithay Root Compositor (wayland-1)                     │ │
│ └────────────────────────────┬────────────────────────────┘ │
│                              ▼                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Labwc Application Window Manager (wayland-0)            │ │
│ └────────────────────────────┬────────────────────────────┘ │
│                              ▼                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Official Brave Origin Browser (brave-origin)            │ │
│ │ Running Natively on Ozone Wayland                       │ │
│ └───────────────┬─────────────────────────┬───────────────┘ │
│                 │                         │                 │
│                 ▼                         ▼                 │
│       /config/profile           /config/downloads           │
│       (Browser Profile)         (Persistent Files)          │
│                 │                                           │
│                 ▼                                           │
│       /config/state/                                        │
│       ├── profile.lock (Authoritative flock)                │
│       ├── last-brave-version (Atomic)                       │
│       └── status (RUNNING, UPDATING, QUIESCED...)           │
│                                                             │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ In-Container Supervisor, Watchdog & Update Daemon       │ │
│ └─────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

---

## Features

- **Native Wayland & Ozone**: Pure Wayland architecture running without X11 or Xwayland overhead. Brave Origin connects directly to Labwc/Smithay using native Ozone.
- **Official Brave Origin Only**: Installed exclusively from Brave's official APT repository (`brave-origin` package). Build verification strictly prohibits standard Brave packages (`brave-browser`).
- **Debian 13 Trixie Slim Base**: Minimal footprint without unnecessary desktop environments, terminals, or background daemons.
- **Hardware Acceleration**: Automatic Intel/AMD GPU detection via `/dev/dri/renderD128` with VAAPI H.264 zero-copy DMA-BUF capture and encoding. Software rasterization fallback when no GPU is present.
- **Unified Audio Streaming**: PulseAudio virtual sink with Rust `pcmflux` Opus audio capture streamed synchronously over the WebSocket connection.
- **Single-Origin TLS (Port 8443)**: Nginx reverse proxy handles TLS termination, static asset delivery, and WebSocket upgrades while Selkies is strictly bound to loopback `127.0.0.1:8082`.
- **Fast Startup & Optimized Ownership**: Verifies `PUID`/`PGID` ownership instantly without performing slow recursive `chown -R` scans across large profile databases on restart.
- **Application Profile Locking**: Uses an exclusive kernel `flock` on `/config/state/profile.lock` held for the lifetime of the browser process to prevent concurrent instances on the same profile.
- **Safe Singleton Recovery**: Removes stale Chromium `SingletonLock` artifacts only after the authoritative `flock` is acquired.
- **Debian-Semantic Downgrade Protection**: Evaluates versions using `dpkg --compare-versions` and prevents launching older binaries against profiles modified by newer versions.
- **Atomic State Tracking**: Updates `/config/state/last-brave-version` only after a verified successful launch using atomic file replacement with `0600` permissions.
- **Backup Consistency Hooks**: Includes `profile-control.sh` to cleanly flush profile databases and suspend browser operations during external filesystem backups or snapshots without stopping the container.
- **Two-Stage Offline Updates**: Pre-downloads package archives in Stage 1 while Brave Origin is running, and installs strictly offline (`--no-download`) in Stage 2 only after downloads succeed.
- **Preserved Chromium Sandboxing**: Runs unprivileged (`braveuser`) with full Chromium user-namespace sandboxing enabled under Docker's standard security model (no `--privileged`, no `--no-sandbox`).

---

## Known Limitations

> [!WARNING]
> **Clipboard Status: UNRESOLVED (Intentionally Deferred)**  
> Seamless bidirectional clipboard synchronization between client browsers and the remote Wayland desktop is currently unresolved and intentionally deferred. Native text clipboard operations (`Ctrl+C` / `Ctrl+V`) across different client browsers are not guaranteed to function reliably in this version.

---

## Requirements

- [Docker](https://docs.docker.com/engine/install/) (v20.10 or later)
- [Docker Compose](https://docs.docker.com/compose/) (v2.0 or later)
- GPU Device (Optional): Intel or AMD GPU with `/dev/dri` passed through for hardware acceleration.

---

## Deployment

### Docker Compose (Recommended)

```yaml
services:
  brave-origin:
    image: forgejo.foss.homes/shoy/brave-origin:wayland
    container_name: brave-origin
    hostname: brave-origin
    restart: unless-stopped
    shm_size: "1gb"
    security_opt:
      - seccomp:unconfined
    devices:
      - /dev/dri:/dev/dri
    ports:
      - "8443:8443"
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=America/New_York
      - AUTH_ENABLED=false
      - AUTO_UPDATE=true
      - ENABLE_AUDIO=true
    volumes:
      - ./appdata:/config
```

### Docker CLI Run Command

```bash
docker run -d \
  --name brave-origin \
  --restart unless-stopped \
  --shm-size 1g \
  --security-opt seccomp=unconfined \
  --device /dev/dri:/dev/dri \
  -p 8443:8443 \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=America/New_York \
  -e AUTH_ENABLED=false \
  -e AUTO_UPDATE=true \
  -e ENABLE_AUDIO=true \
  -v /mnt/user/appdata/brave-origin:/config \
  forgejo.foss.homes/shoy/brave-origin:wayland
```

---

## Persistent Storage (`/config`) Layout

| Path | Purpose |
|---|---|
| `/config/profile/` | Persistent Brave Origin user profile (bookmarks, history, extensions, preferences). |
| `/config/downloads/` | Default browser download directory. |
| `/config/state/` | Runtime state tracking (`profile.lock`, `last-brave-version`, `status`, logs). |
| `/config/ssl/` | Generated or user-provided SSL/TLS certificates (`cert.pem`, `cert.key`). |
| `/config/.passwd` | HTTP Basic Authentication credentials (when `AUTH_ENABLED=true`). |

---

## Environment Variables

| Variable | Default | Purpose |
|---|---|---|
| `PUID` | `1000` | User ID for container process execution and file permissions. |
| `PGID` | `1000` | Group ID for container process execution and file permissions. |
| `UMASK` | `022` | File creation permission mask for downloads and config files. |
| `TZ` | `Etc/UTC` | Timezone setting for container logs and browser clock. |
| `AUTH_ENABLED` | `false` | Enable HTTP Basic Authentication on ingress port 8443. |
| `AUTH_USER` | `brave` | Username when `AUTH_ENABLED=true`. |
| `AUTH_PASSWORD` | *(empty)* | Initial password when `AUTH_ENABLED=true`. |
| `ENABLE_AUDIO` | `true` | Enable PulseAudio virtual sink and WebSocket Opus streaming. |
| `AUTO_UPDATE` | `true` | Enable automated two-stage offline updates for Brave Origin. |
| `UPDATE_INTERVAL` | `21600` | Update verification interval in seconds (default: 6 hours). |
| `MIN_UPDATE_FREE_SPACE_MB`| `1024` | Minimum free disk space on root filesystem required to initiate an update. |

---

## Password Management

To change or generate authentication credentials on a running container:

```bash
# Set a specific password:
docker exec brave-origin /usr/local/bin/reset-password.sh "YourNewPassword123!"

# Generate a random secure password:
docker exec brave-origin /usr/local/bin/reset-password.sh --generate
```

---

## Backup Consistency Hooks (`profile-control.sh`)

For consistent snapshots or appdata backups without stopping the container:

```bash
# Pre-backup: flush SQLite databases and suspend browser
docker exec brave-origin /usr/local/bin/profile-control.sh quiesce

# (Perform your backup / snapshot of /config here)

# Post-backup: resume normal browser operations
docker exec brave-origin /usr/local/bin/profile-control.sh resume
```

To query container state:

```bash
docker exec brave-origin /usr/local/bin/profile-control.sh status
# Returns: RUNNING, UPDATING, QUIESCED, STARTING, or ERROR
```

---

## Automatic Brave Origin Updates

Brave Origin updates automatically inside the container without rebuilding the Docker image:

1. **Space Pre-Check**: Verifies that root partition `/` has at least `MIN_UPDATE_FREE_SPACE_MB` (default: 1024MB) available before downloading packages.
2. **Stage 1 (Pre-Download)**: Downloads package archives into local cache while Brave Origin remains running online. If network/download fails, the browser is untouched.
3. **Stage 2 (Offline Install)**: Stops Brave Origin to flush databases, installs strictly from local cache using `--no-download`, and relaunches the upgraded binary without dropping your remote KasmVNC session.
4. **Lock Coordination**: All update modes share `/run/lock/brave-origin-update.lock` using non-blocking `flock`.

### Triggering a Manual Update Check

```bash
docker compose exec brave-origin /usr/local/bin/update-brave.sh
```

---

## Custom SSL / TLS Certificates

If you own a custom SSL certificate (e.g. from Let's Encrypt), place your PEM-formatted certificate and private key in `./appdata/kasmvnc/certs/`:

- `./appdata/kasmvnc/certs/kasmvnc.pem` (Certificate chain)
- `./appdata/kasmvnc/certs/kasmvnc.key` (Private key)

Restart the container with `docker compose restart`.

---

## GPU Acceleration & Rendering Options

### Software Rendering (Default)
By default, the container operates with CPU software rendering without requiring host GPU device nodes. This is suitable for Docker Desktop (Windows/macOS) and headless servers.

### Intel / AMD Graphics Passthrough (Linux / Unraid)
On Linux or Unraid systems with `/dev/dri` available, pass the GPU device using `compose.gpu.yaml`:

```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d
```

### NVIDIA Graphics
NVIDIA container GPU acceleration is currently unvalidated/future work for this image. Do not run in privileged mode or weaken sandboxing to attempt NVIDIA injection.

---

## Troubleshooting

### Browser tab crashes / Out of memory
Chromium browsers require adequate shared memory (`/dev/shm`). `compose.yaml` is pre-configured with `shm_size: "1gb"`. Increase to `"2gb"` if running dozens of heavy media tabs.

### Profile Downgrade Warning in Logs
If the log shows `[DOWNGRADE BLOCKED] Profile Protection Active`, the profile was previously opened by a newer version of Brave Origin than what is currently installed. The container enters recovery mode and will automatically update `brave-origin` to a compatible version once repository access is restored.

### Viewing Live Logs
```bash
docker compose logs -f brave-origin
```

---

## Repository Structure

```text
brave-origin-docker/
├── Dockerfile
├── compose.yaml
├── compose.gpu.yaml
├── .env.example
├── .dockerignore
├── .gitignore
├── entrypoint.sh
├── README.md
├── AGENTS.md
├── CLAUDE.md
├── config/
│   ├── audio-client.js
│   ├── kasmvnc.yaml
│   └── nginx.conf
├── scripts/
│   ├── audio-server.py
│   ├── profile-control.sh
│   ├── reset-password.sh
│   ├── start-session.sh
│   └── update-brave.sh
└── skills/
    ├── file-upload/
    ├── frontend-design/
    └── html-communication/
```

---

## License

This Docker deployment is provided under the [MIT License](LICENSE). Brave Origin and the Brave logo are trademarks of Brave Software, Inc. KasmVNC is an open-source project by Kasm Technologies.
