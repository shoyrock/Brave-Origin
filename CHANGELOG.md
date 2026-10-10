# Release notes

## Unreleased security updates

- Fixed startup on hosts without IPv6: the web proxy now listens on IPv4 only when the kernel has no IPv6 support instead of stopping the container.
- Improved protection for saved browser data, login details, and certificates.
- Blocked remote-session requests from unrelated websites.
- Added security checks before publishing images.
- Fixed startup on networks without internet access.

Stable publication is on hold while dependency security findings remain unresolved.

## X11 1.0.0

First stable X11 edition for users who prefer KasmVNC.

- Browse with saved bookmarks, settings, downloads, copy and paste, and audio.
- Fixed native paste and added a **Paste to session** button.
- Improved login protection, browser updates, backups, and shutdown.
- Added an X11 Unraid template and separate stable and beta update channels.

Upgrading an older X11 image requires setting an initial login password. Back up appdata before upgrading.
