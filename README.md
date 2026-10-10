# Brave Origin in Docker

> Testing release: `1.0.1-beta.2` fixes automatic resizing, keeps Brave maximized, and includes application security fixes. Known dependency vulnerabilities remain, so it is not security-cleared for production. Stable `1.0.0` images do not include these fixes. See [security guidance](SECURITY.md).

Run Brave Origin in a web browser over HTTPS. Your bookmarks, settings, extensions, and downloads stay in a persistent folder. The container uses Debian 13 Trixie Slim and the official stable `brave-origin` package.

**Stable release: 1.0.0.** Use `latest` for stable updates or pin `1.0.0` to keep this container version. Development builds use `beta` and need a separate appdata folder.

Wayland is the default desktop. The X11 edition uses KasmVNC. Both have stable and beta image channels; choose one during installation.

## Unraid

The [Unraid template](templates/brave-origin.xml) defaults to **Wayland stable (`latest`)**. It uses bridge networking, HTTPS, and Unraid's user ID 99 and group ID 100.

When installed through **Apps / Community Applications**, Brave-Origin offers these choices:

| Choice | Image tag | Container name | Appdata folder | HTTPS port |
| --- | --- | --- | --- | --- |
| **Default: Wayland stable** | `latest` | `Brave-Origin` | `/mnt/user/appdata/brave-origin` | `8443` |
| Wayland beta | `beta` | `Brave-Origin-Beta` | `/mnt/user/appdata/brave-origin-beta` | `8444` |
| X11 stable | `x11` | `Brave-Origin-X11` | `/mnt/user/appdata/brave-origin-x11` | `8445` |
| X11 beta | `x11-beta` | `Brave-Origin-X11-Beta` | `/mnt/user/appdata/brave-origin-x11-beta` | `8446` |

Each choice uses `ghcr.io/shoyrock/brave-origin` with the tag shown above. Select a channel, set a password, review the storage path and port, then apply. Open the container's **WebUI** menu to start browsing. The separate defaults let you test another channel alongside your existing container; choose a different port if one is already in use.

Beta refers to the container's development channel. Every channel installs the official stable Brave Origin browser package. A beta tag can match its stable counterpart until a new test image is published; `x11-beta` currently matches `x11`.

### Manual installation

If Brave-Origin is not yet listed in Apps, install the template from the Unraid terminal:

```bash
mkdir -p /boot/config/plugins/dockerMan/templates-user
curl -fL https://raw.githubusercontent.com/shoyrock/Brave-Origin/main/templates/brave-origin.xml \
  -o /boot/config/plugins/dockerMan/templates-user/my-brave-origin.xml
```

In **Docker → Add Container**, select **Brave-Origin**. This manual screen does not show the Community Applications channel menu. To choose another channel, enable **Advanced View**, change **Repository** to `ghcr.io/shoyrock/brave-origin:` followed by the desired tag, and set the name, appdata folder, and host port from the table. Set a password, then apply.

For manual X11 installations, the [X11 template](https://github.com/shoyrock/Brave-Origin/blob/x11/templates/brave-origin.xml) supplies X11-specific settings. Wayland's **Automatic Display Resize** and **Keep Browser Maximized** settings do not apply to X11.

For Intel or AMD graphics, add a **Device** mapping from `/dev/dri` to `/dev/dri` in the advanced template view. Leave this mapping out on systems without that device. Installation through the Unraid web interface has not been verified on this development host.

### Changing an existing installation

Edit the container, enable **Advanced View**, and change the tag in **Repository**. Applying the change pulls that channel's image. Existing installations keep their saved name, port, and appdata path; the new template defaults do not change them automatically. Back up appdata before switching channels. Never run stable and beta containers against the same live profile.

## Other Linux hosts (Docker Compose)

You need an x86-64 Linux host with Docker and Docker Compose v2. GPU access is optional.

```bash
git clone https://github.com/shoyrock/Brave-Origin.git
cd Brave-Origin
cp .env.example .env
```

Edit `.env` and set `AUTH_PASSWORD` to a password of your choice. Then start the container:

```bash
docker compose pull
docker compose up -d --no-build
```

Open `https://YOUR-SERVER-IP:8443` and sign in as `brave`. The container creates a self-signed certificate, so your browser will show a certificate warning. For a trusted connection, supply your own certificate as described below.

The public image is available as `ghcr.io/shoyrock/brave-origin:latest`.

Set `IMAGE_NAME` in `.env` to choose a specific version or another registry. To build from source, run `docker compose build` followed by `docker compose up -d --no-build`.

## Copy and paste

Use Ctrl+C and Ctrl+V inside the remote session. On macOS, use the shortcuts supported by your client browser. Text can move in both directions, including Unicode and multiple lines. The server also supports image clipboard transfer when the client enables it.

Clipboard access depends on your client browser's permissions and a secure context. Allow clipboard access when prompted and keep the session page focused. If automatic clipboard access is blocked, open **Clipboard** in the sidebar, enter your text, click **Send to session**, then paste inside Brave. Chromium-based clients also support native paste events, including paste from the browser menu. Clipboard permissions and image support vary by client browser.

## Settings

Set these values in `.env`, the Unraid template, or your container's environment.

| Setting | Default | Purpose |
| --- | --- | --- |
| `CONFIG_PATH` | `./appdata` | Compose host folder mounted at `/config`. |
| `IMAGE_NAME` | `ghcr.io/shoyrock/brave-origin:latest` | Compose image and release channel. |
| `WEB_PORT` | `8443` | Compose host port. The container always listens on 8443. |
| `PUID` / `PGID` | `1000` / `1000` | Nonzero user and group IDs for browser files. |
| `UMASK` | `022` | File creation permissions. |
| `TZ` | `Etc/UTC` | Timezone. |
| `AUTH_ENABLED` | `true` | Require a login. Disable only when access is already restricted by your network or proxy. |
| `AUTH_USER` | `brave` | Initial login username. |
| `AUTH_PASSWORD` | Empty | Initial password; required unless a password file or saved credentials exist. |
| `AUTH_PASSWORD_FILE` | Empty | Path inside the container to a mounted password file. |
| `AUTO_UPDATE` | `true` | Update the browser inside the running container. |
| `UPDATE_INTERVAL` | `21600` | Seconds between update checks (six hours). |
| `MIN_UPDATE_FREE_SPACE_MB` | `1024` | Free disk space required before downloading an update. |
| `BRAVE_ORIGIN_VERSION` | `latest` | Browser package version to request. Older versions are never installed over newer ones. |
| `DOWNGRADE_RETRY_INTERVAL` | `300` | Seconds before retrying a session blocked by an older browser. |
| `BRAVE_STARTUP_TIMEOUT` | `15` | Seconds the resume command waits before reporting that startup is pending. |
| `ENABLE_AUDIO` | `true` | Stream session audio. |
| `ENABLE_GPU` | `true` | Use available GPU hardware for browser rendering. |
| `DRI_NODE` | `/dev/dri/renderD128` | Render device when a GPU is passed through. |
| `DISPLAY_AUTO_RESIZE` | `true` | Automatically resize the desktop to the browser window, including 1440p, 4K, and ultrawide displays. |
| `DISPLAY_WIDTH` / `DISPLAY_HEIGHT` | `1920` / `1080` | Fixed desktop size, used only when `DISPLAY_AUTO_RESIZE=false`. |
| `BROWSER_LOCK_MAXIMIZED` | `true` | Keep Brave maximized. Set to `false` to allow minimizing, restoring, and dragging its windows. |
| `BRAVE_FLAGS` | Empty | Extra space-separated browser arguments. Shell quoting is not interpreted; flags that disable the sandbox or change the profile are rejected. |
| `CONTAINER_HOSTNAME` | `brave-origin` | Compose container hostname. |

Automatic resizing follows the available browser window, including changes when you maximize or resize it. Existing width and height values no longer lock the desktop unless you set `DISPLAY_AUTO_RESIZE=false`. Use `beta` or `1.0.1-beta.2` for this fix; it is not included in the stable 1.0.0 images.

Starting with `1.0.1-beta.2`, Brave stays maximized: minimize, restore, and window dragging cannot take it off screen or make it smaller. Its title-bar buttons remain visible. Tabs, the address bar, and automatic display resizing continue to work. Set `BROWSER_LOCK_MAXIMIZED=false` and recreate the container to restore the previous window controls. In Unraid, this is **Keep Browser Maximized**.

This behavior belongs to the container's window manager. Brave remains the official, unmodified package and can receive browser updates independently. The image includes the modified Labwc 0.8.3 source at `/usr/local/share/brave-origin/labwc-source.tar.xz`; its build recipe is in `Dockerfile` and its changes are in `patches/labwc/lock-maximized.patch`.

The older `KASM_AUTH_ENABLED`, `KASM_USER`, `KASM_PASSWORD`, and `KASM_PASSWORD_FILE` names remain accepted. The corresponding `AUTH_*` setting takes precedence.

Saved credentials take precedence over password environment variables. On first setup, a password file takes precedence over `AUTH_PASSWORD`; an unreadable or empty file stops startup. New and reset passwords use bcrypt hashes. Existing saved credentials are retained.

To change a saved password:

```bash
docker exec brave-origin /usr/local/bin/reset-password.sh --generate
```

The generated password is printed to that command's output. Save it securely. You can also pass a chosen password as the argument, but doing so can leave it in your shell history. Resetting a password does not enable authentication if you explicitly disabled it.

## Storage and backups

| Container path | Contents |
| --- | --- |
| `/config/profile` | Browser profile, bookmarks, history, and extensions. |
| `/config/downloads` | Downloads and files transferred through the session. |
| `/config/state` | Locks, version records, status, and logs. |
| `/config/ssl` | HTTPS certificate and private key. |
| `/config/.passwd` | Saved login credentials. |

Back up the entire appdata folder while the container is stopped. For backups without stopping the container, pause the browser first:

```bash
docker exec brave-origin /usr/local/bin/profile-control.sh quiesce
# Back up your appdata folder after the command succeeds.
docker exec brave-origin /usr/local/bin/profile-control.sh resume
```

The backup command waits for the profile lock and flushes writes before reporting success. A failed command means the profile is not ready for backup. A backup hold persists across container restarts until you run `resume`.

Run `docker exec brave-origin /usr/local/bin/profile-control.sh status` to inspect the session. A healthy container can be paused for backup. A browser that is too old for the saved profile reports `DOWNGRADE_BLOCKED` and does not open the profile.

The `/config` mount root, login file, TLS directory, and lifetime locks belong to root. Browser data directories remain writable by `PUID` and `PGID`. Do not recursively change ownership of the whole appdata folder. Nginx access and error logs are available through `docker logs`.

Changing `PUID` or `PGID` repairs profile ownership at the next startup. This can take time for a large profile. Do not run two containers against the same appdata folder.

## Updates and release channels

Browser updates download first while the browser stays open. After the download succeeds, the browser closes, the package installs from the local cache, and the session restarts. Expect a brief interruption. A download failure leaves the browser running. Failed installation recovery also uses cached packages only.

To check for a browser update manually:

```bash
docker exec brave-origin /usr/local/bin/update-brave.sh
```

Container updates are separate: use `docker compose pull` and `docker compose up -d --no-build`, or Unraid's container update controls.

- `beta` is the development branch and image tag. It receives tested development builds.
- `main` holds release preparation and stable code. A push to `main` builds and tests but does not publish images.
- A tag such as `v1.0.0-beta.1` publishes a beta version. It does not change `latest`.
- A stable tag such as `v1.0.0`, created from `main`, publishes the version and updates `latest` in both registries.

The first stable container release is `1.0.0`. Back up appdata before moving from older `wayland` images. Never run stable and beta containers against the same live profile. See [release notes](CHANGELOG.md) for changes and [the release guide](RELEASING.md) for maintainer steps.

## HTTPS and access

The web session provides access to the browser profile and downloaded files. Keep it behind a trusted network, VPN, or authenticated proxy. Login protection is enabled by default. A reverse proxy must preserve the original `Host` header, including a nonstandard port. Requests from unrelated website origins are rejected.

Brave runs as `braveuser` with its Chromium sandbox enabled. The supplied configuration uses `seccomp:unconfined` so the browser can create user namespaces; this disables Docker's syscall filter for this container. The host must permit unprivileged user namespaces. `no-new-privileges` prevents child processes from gaining permissions through setuid programs. Do not add `--no-sandbox`, privileged mode, or `SYS_ADMIN`.

The supplied Compose file and Unraid template also drop every Linux capability except the few that startup, nginx, and browser updates need (`CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `SETGID`, `SETUID`, `KILL`) and limit the container to 2048 processes. Inside the image, setuid bits and file capabilities are removed from everything except Brave's own sandbox helper. Rejected logins are delayed by one second, and responses carry `X-Frame-Options`, `Referrer-Policy`, and `X-Content-Type-Options` headers in addition to the frame-ancestors policy. If you run the container with your own `docker run` command, copy these options from `compose.yaml`.

To use your own TLS certificate, place its certificate chain at `/config/ssl/cert.pem` and its private key at `/config/ssl/cert.key`, then restart the container. A simple nginx reload does not copy newly supplied files into place.

## GPU support

Without a GPU mapping, the container uses software rendering. With an Intel or AMD GPU available, start Compose with:

```bash
docker compose -f compose.yaml -f compose.gpu.yaml up -d --no-build
```

Browser hardware rendering, WebGL, and video decoding were verified on Intel graphics. Stream encoding can fall back to the CPU when a driver does not support the requested format. Support varies by GPU and host driver; `ENABLE_GPU=false` disables browser GPU rendering.

## License

This container project uses the [MIT License](LICENSE). Brave Origin, Selkies, and the other included components retain their own licenses. Brave Origin and the Brave logo are trademarks of Brave Software, Inc. This project is unofficial and is not affiliated with or endorsed by Brave Software, Inc.
