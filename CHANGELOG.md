# Release notes

## Unreleased

- Fixed startup on hosts without IPv6: the web proxy now listens on IPv4 only when the kernel has no IPv6 support instead of stopping the container.

## X11 1.0.0

First stable X11 edition for users who prefer KasmVNC.

- Browse with saved bookmarks, settings, downloads, copy and paste, and audio.
- Fixed native paste and added a **Paste to session** button.
- Improved login protection, browser updates, backups, and shutdown.
- Added an X11 Unraid template and separate stable and beta update channels.

Upgrading an older X11 image requires setting an initial login password. Back up appdata before upgrading.
