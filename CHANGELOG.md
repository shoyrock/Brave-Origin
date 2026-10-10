# Release notes

## Unreleased

- Fixed startup on hosts without IPv6: the web proxy now listens on IPv4 only when the kernel has no IPv6 support instead of stopping the container.
- Hardened the container: the Compose file and Unraid template drop all Linux capabilities except the six the container needs and limit it to 2048 processes; the image removes setuid bits and file capabilities from everything except Brave's sandbox helper, drops the unused GnuPG tools, and applies Debian security updates at build time.
- Hardened the web proxy: forward-secret TLS cipher suites only, a one-second delay after each rejected login, and `X-Frame-Options` and `Referrer-Policy` headers on every response.

## 1.0.1-beta.2

- Brave now stays maximized when you click minimize or restore, or drag the window.
- Added a setting to bring back the previous window controls.

Testing release only. Known dependency vulnerabilities remain; use a separate profile on a trusted network. Stable publication remains on hold.

## 1.0.1-beta.1

- Fixed black bars by automatically resizing the desktop to fit the browser window.
- Improved protection for saved browser data, login details, and certificates.
- Blocked remote-session requests from unrelated websites.
- Added security checks before publishing images.

Testing release only. Known dependency vulnerabilities remain; use a separate profile on a trusted network. Stable publication remains on hold.

## 1.0.0

First stable release.

- Run Brave Origin remotely with saved profiles, password protection, and audio.
- Fixed native copy and paste, and added a **Send to session** clipboard button.
- Fixed audio after stopping and restarting the stream.
- Improved shutdown so browser profiles are saved before the container stops.
- Corrected the Unraid template and kept development builds separate from stable updates.

## 1.0.0-beta.1

- Added password protection by default and improved password storage.
- Fixed copy and paste for more text formats, including Unicode and multiple lines.
- Fixed browser restarts after backups and updates.
- Added protection against opening a profile with an older browser.
- Corrected the Unraid setup template and simplified the setup instructions.
- Separated beta builds from stable releases.

This earlier prerelease has been superseded by 1.0.0.
