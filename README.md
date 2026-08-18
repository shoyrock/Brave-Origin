# Brave Origin in Docker (KasmVNC Web Access)

A production-grade, lightweight Docker solution for **Brave Origin** built on **Debian 13 Trixie Slim** and accessed remotely from any modern web browser via **KasmVNC** over HTTPS. Designed for normal Unraid Docker deployment and compatible with standard Unraid appdata/PUID/PGID/device mapping conventions, storage-agnostic persistence, atomic profile state tracking, application-level profile locking, safe backup quiescing, application watchdog crash backoff, unprivileged execution, preserved Chromium sandboxing, and two-stage transaction-safe browser updates.

```text
┌─────────────────────────────────────────────────────────────┐
│ Client Device (Chrome / Brave / Firefox / Safari / Mobile)  │
└──────────────────────────────┬──────────────────────────────┘
                               │
                               │ HTTPS (Port 8443)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│ Docker Container (Debian 13 Trixie Slim)                    │
│                                                             │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ KasmVNC Server (WebSockets + H.264/WebP/JPEG + TLS)     │ │
│ └────────────────────────────┬────────────────────────────┘ │
│                              ▼                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Openbox Window Manager (Auto-Maximize + Focus)          │ │
│ └────────────────────────────┬────────────────────────────┘ │
│                              ▼                              │
│ ┌─────────────────────────────────────────────────────────┐ │
│ │ Official Brave Origin Browser (brave-origin)            │ │
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

- **Official Brave Origin Only**: Installed exclusively from Brave's official APT repository (`brave-origin` package). Build verification strictly prohibits standard Brave packages (`brave-browser`).
- **Debian 13 Trixie Slim Base**: Minimal footprint without unnecessary desktop environments, terminals, or background daemons.
- **Application Watchdog with Bounded Backoff**: Automatically relaunches Brave Origin if the browser window is closed or crashes during normal `RUNNING` state, with bounded backoff (10s -> 30s -> 60s -> `ERROR` state) to prevent infinite restart loops.
- **Fast Startup & Optimized Ownership**: Verifies `PUID`/`PGID` ownership instantly without performing slow recursive `chown -R` scans across large profile databases on every restart.
- **Secrets from Files Support**: Supports `KASM_PASSWORD_FILE` (pointing to mounted Docker secret files or host paths) in addition to direct `KASM_PASSWORD` environment variables.
- **Configurable UMASK**: Supports `UMASK=022` for predictable persistent file permissions on Unraid and Linux hosts.
- **Storage-Agnostic `/config`**: Runs cleanly on any local storage mount (including Unraid user shares, ZFS datasets, Btrfs subvolumes, LVM, ext4, or XFS). Host path configurable via `CONFIG_PATH`.
- **Application Profile Locking**: Uses an exclusive kernel `flock` on `/config/state/profile.lock` held for the lifetime of the browser process to prevent concurrent instances on the same profile.
- **Safe Singleton Recovery**: Removes stale Chromium `SingletonLock` artifacts only after the authoritative `flock` is acquired and no active browser process is running in the container.
- **Debian-Semantic Downgrade Protection**: Evaluates versions using `dpkg --compare-versions` and prevents launching older binaries against profiles modified by newer versions.
- **Atomic State Tracking**: Updates `/config/state/last-brave-version` only after a verified successful launch using atomic file replacement with `0600` permissions.
- **Backup Consistency Hooks**: Includes `profile-control.sh` to cleanly flush profile databases and suspend browser operations during external filesystem backups or snapshots without stopping the container.
- **Two-Stage Offline Updates**: Pre-downloads package archives in Stage 1 while Brave Origin is running, and installs strictly offline (`--no-download`) in Stage 2 only after downloads succeed.
- **Conservative Free Space Checks**: Checks root filesystem `/` against `MIN_UPDATE_FREE_SPACE_MB` (default: 1024MB safety floor) independently of `/config` storage.
- **Stable Hostname**: Preserves container hostname across recreations (`CONTAINER_HOSTNAME=brave-origin`) to avoid Chromium singleton confusion.
- **Direct HTTPS Web Client**: Powered by KasmVNC 1.5.0 with dynamic resolution resizing, full-screen, high-DPI, and 2-way clipboard sync.
- **Ephemeral Browser Cache**: Directs disposable browser disk cache to `/tmp/brave-cache` to keep persistent backups compact and reduce disk writes.
- **Preserved Chromium Sandboxing**: Runs unprivileged (`braveuser`) with full Chromium user-namespace sandboxing enabled under Docker's standard security model (no `--privileged`, no `--no-sandbox`).
- **Multi-Architecture**: Built for `linux/amd64` and `linux/arm64`.

---

## Requirements

- [Docker](https://docs.docker.com/engine/install/) (v20.10 or later)
- [Docker Compose](https://docs.docker.com/compose/) (v2.0 or later)

---

## Quick Start

### 1. Clone or Download Repository

```bash
git clone https://github.com/your-username/brave-origin-docker.git
cd brave-origin-docker
```

### 2. Configure Environment & Credentials

Copy the example environment file:

```bash
cp .env.example .env
```

Edit `.env` to configure your storage location, username, or port:

```ini
CONFIG_PATH=./appdata
# Example for Unraid OS deployments:
# CONFIG_PATH=/mnt/user/appdata/brave-origin

KASM_USER=brave
KASM_PASSWORD=MySecurePassword123!
WEB_PORT=8443
```

#### First-Boot Interactive Password Initialization (Optional)
If you prefer not to write passwords in `.env`, leave `KASM_PASSWORD=` empty and initialize credentials interactively:
```bash
docker compose run --rm brave-origin /usr/local/bin/reset-password.sh --generate
```
This displays the generated password once directly on your terminal and stores the obfuscated credential file in `/config/kasmvnc/.kasmpasswd` (mode `0600`) without printing passwords to container daemon logs.

### 3. Build & Launch

#### Standard Software-Rendered Mode (Default):
```bash
docker compose up -d --build
```

#### With Optional Intel/AMD GPU Hardware Acceleration (Linux / Unraid):
```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d --build
```

### 4. Connect via Web Browser

Open your browser and navigate to:

```text
https://localhost:8443
```

*(If accessing from another device on your network, use `https://<HOST-IP>:8443`)*

> [!NOTE]
> Because KasmVNC generates a self-signed TLS certificate by default, your browser will display a certificate warning on first visit. Accept the certificate to proceed to the login page, then enter your `KASM_USER` and password.

---

## Technical Comparison: KasmVNC vs. Selkies

| Evaluation Metric | Current Implementation (KasmVNC + Openbox) | Reference Project (Selkies + Wayland + Labwc) |
| :--- | :--- | :--- |
| **Primary Protocol** | WebSocket + Tile-based Adaptive Video/JPEG/WebP | WebRTC / GStreamer H.264/VP9/AV1 Video Stream |
| **Workload Optimization** | **Static text clarity**, subpixel rendering, web reading | **High-motion workloads**, cloud gaming, 3D graphics |
| **Dependencies & Footprint** | KasmVNC has fewer remote-desktop framework dependencies | Requires custom patched `wlroots`, `dind`, Python venvs |
| **Security & UI Surface** | **Hardened browser-only**; no terminal, no sudo, no desktop menu | Exposes root `sudo`, `xterm`, `foot`, `proot-apps`, desktop menus |
| **Chromium Sandboxing** | **Fully Enabled** (Unprivileged Chromium User Namespaces) | Disabled in reference (`--no-sandbox`, `--test-type`) |
| **Browser Compatibility** | Works across all modern desktop & mobile browsers over HTTPS/WSS | Requires WebRTC ICE/STUN/TURN network negotiation |
| **Potential Advantages** | Low idle CPU, sharp text, native Debian Trixie `.deb` package | Potential zero-copy GPU video streaming & lower motion latency |

**Architecture Decision**: KasmVNC remains the preferred implementation for the current project because it is already integrated, preserves the project's security model, and avoids a major architecture migration before baseline testing. Selkies + Wayland may be re-evaluated for zero-copy GPU workloads after actual performance testing if a minimal headless build with preserved Chromium sandboxing becomes viable.

---

## Base OS vs. Browser Update Strategy

- **Brave Origin Browser Updates**: Handled automatically in-container by `scripts/update-brave.sh` via a two-stage offline transaction without requiring container restarts or image rebuilds.
- **Base OS / KasmVNC Updates**: Handled by rebuilding the Docker container image periodically when upstream Debian 13 Trixie or KasmVNC release security patches:

```bash
# Rebuild image with latest Debian Trixie security patches:
docker compose build --pull
docker compose up -d
```

---

## Sensitive Storage & Backup Warning

> [!CAUTION]
> The `/config` persistent directory contains sensitive personal and credential material, including:
> - Browser history, bookmarks, and cookies
> - Active login sessions and authentication tokens
> - Saved passwords and autofill data
> - Brave Sync configuration and encryption seeds
> - KasmVNC authentication credentials (`/config/kasmvnc/.kasmpasswd`)
> - TLS private keys (`/config/kasmvnc/certs/kasmvnc.key`)
>
> **Note on KasmVNC credentials**: `/config/kasmvnc/.kasmpasswd` uses an obfuscated representation (mode `0600`), not a cryptographically salted one-way hash.
> 
> All backups, archives, and storage snapshots containing `/config` must be stored on encrypted volumes and protected with appropriate access controls.

---

## Persistent Storage Layout

```text
/config/
├── profile/             # Complete Chromium user profile (history, bookmarks, cookies, extensions, databases)
├── downloads/           # Downloaded files destination
├── kasmvnc/             # KasmVNC server configuration and authentication
│   ├── kasmvnc.yaml
│   ├── .kasmpasswd      # Obfuscated credentials file (mode 0600, sensitive)
│   └── certs/
│       ├── kasmvnc.pem  # TLS certificate chain
│       └── kasmvnc.key  # TLS private key (mode 0600, sensitive)
└── state/               # Internal application state (snapshot-friendly)
    ├── profile.lock     # Authoritative flock for profile concurrency control
    ├── last-brave-version # Atomically written version of most recent successful launch
    └── status           # Current status: RUNNING, UPDATING, DOWNGRADE_RECOVERY, QUIESCED
```

Disposable browser cache is stored in `/tmp/brave-cache` in container ephemeral memory/storage, ensuring `/config` remains clean and snapshot-friendly.

---

## Credentials Management

### Resetting Password
To reset or change credentials at any time, run:

```bash
# Set a specific new password:
docker compose exec brave-origin /usr/local/bin/reset-password.sh "MyNewPassword123!"

# Or generate a new random password:
docker compose exec brave-origin /usr/local/bin/reset-password.sh --generate
```

---

## Backup Consistency Hooks

For point-in-time consistent backups and external snapshots (such as ZFS, Btrfs, LVM, or Unraid backup scripts), use `profile-control.sh`:

```bash
# 1. Quiesce profile (flushes SQLite databases, stops Brave Origin, and synchronizes filesystem):
docker compose exec brave-origin /usr/local/bin/profile-control.sh quiesce

# 2. Perform external snapshot or cold backup:
# e.g., tar -czvf brave-origin-backup.tar.gz ./appdata
# or zfs snapshot pool/appdata/brave-origin@backup_$(date +%Y%m%d)

# 3. Resume browser operations:
docker compose exec brave-origin /usr/local/bin/profile-control.sh resume
```

To query the current state of the browser container:
```bash
docker compose exec brave-origin /usr/local/bin/profile-control.sh status
# Returns: RUNNING, UPDATING, DOWNGRADE_RECOVERY, QUIESCED, STARTING, or ERROR
```

---

## Profile Downgrade Protection & Recovery

Chromium profiles undergo irreversible database migrations (SQLite schemas, LevelDB keys, IndexedDB) when newer versions run. Launching an older version of Brave Origin against an upgraded profile will corrupt extensions, history, and preferences.

### How Protection Works:
1. **Debian Comparison Semantics**: All checks evaluate version compatibility using `dpkg --compare-versions "$INSTALLED" ge "$LAST_RECORDED"`.
2. **Atomic Version Tracking**: Whenever Brave Origin launches successfully, its version is written to `/config/state/last-brave-version.tmp.$$` and atomically moved to `/config/state/last-brave-version` with `0600` permissions after a stabilization verification period (`BRAVE_STARTUP_TIMEOUT=15`).
3. **Downgrade Blocking**: If an older container image is deployed or the repository is temporarily unreachable while the installed version is older than `/config/state/last-brave-version`, Brave Origin launch is **paused**.
4. **Automatic Downgrade Recovery**: KasmVNC remains accessible while the supervisor enters recovery mode, retrying the official repository every `DOWNGRADE_RETRY_INTERVAL` (default: 300s / 5 minutes). Once a compatible version is installed, Brave Origin immediately launches and exits recovery mode.

---

## Environment Variables

| Variable | Default | Description |
| :--- | :--- | :--- |
| `CONFIG_PATH` | `./appdata` | Host persistent directory path (supports local folders or `/mnt/user/appdata/brave-origin`) |
| `CONTAINER_HOSTNAME` | `brave-origin` | Stable container hostname to prevent singleton identity churn |
| `WEB_PORT` | `8443` | Host port mapped to KasmVNC HTTPS interface |
| `KASM_USER` | `brave` | KasmVNC HTTP authentication username |
| `KASM_PASSWORD` | `""` | KasmVNC password (leave blank to initialize interactively) |
| `KASM_PASSWORD_FILE` | `""` | Path to mounted secret file containing password inside container |
| `PUID` | `1000` | Host User ID mapped to container user (`99` for Unraid, `1000` for standard Linux) |
| `PGID` | `1000` | Host Group ID mapped to container user (`100` for Unraid, `1000` for standard Linux) |
| `UMASK` | `022` | File creation mask for persistent files |
| `TZ` | `America/New_York` | Container timezone |
| `DISPLAY_WIDTH` | `1920` | Initial virtual desktop width in pixels |
| `DISPLAY_HEIGHT` | `1080` | Initial virtual desktop height in pixels |
| `AUTO_UPDATE` | `true` | Enable in-container automatic Brave Origin updates |
| `UPDATE_INTERVAL` | `21600` | Periodic update check interval in seconds (21600 = 6 hours) |
| `DOWNGRADE_RETRY_INTERVAL` | `300` | Recovery retry interval when launch is paused (300 = 5 minutes) |
| `MIN_UPDATE_FREE_SPACE_MB` | `1024` | Minimum free space in MB on root `/` required to start update |
| `BRAVE_STARTUP_TIMEOUT` | `15` | Browser startup stabilization timeout in seconds |
| `BRAVE_ORIGIN_VERSION`| `latest` | Pin a specific package version (e.g. `1.93.136`) or use `latest` |
| `ENABLE_GPU` | `true` | Enable GPU hardware acceleration if supported and `/dev/dri` is passed |
| `ENABLE_AUDIO` | `true` | Enable audio subsystem |
| `DRI_NODE` | `/dev/dri/renderD128` | Direct Rendering Infrastructure node for hardware acceleration |
| `BRAVE_FLAGS` | `""` | Extra CLI flags passed to Brave Origin (e.g. `"--incognito"`) |

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
By default, the container operates with robust software rendering via CPU without requiring host GPU device nodes. This is suitable for Docker Desktop (Windows/macOS) and headless servers.

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
│   └── kasmvnc.yaml
├── scripts/
│   ├── start-session.sh
│   ├── update-brave.sh
│   ├── profile-control.sh
│   └── reset-password.sh
└── skills/
    ├── file-upload/
    ├── frontend-design/
    └── html-communication/
```

---

## License

This Docker deployment is provided under the [MIT License](LICENSE). Brave Origin and the Brave logo are trademarks of Brave Software, Inc. KasmVNC is an open-source project by Kasm Technologies.
