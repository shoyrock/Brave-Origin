# Labwc browser maximization policy

Based on upstream Labwc 0.8.3, licensed GPL-2.0-only. Modified for Brave Origin
on September 8, 2026. The Dockerfile pins the official source archive by SHA-256.

The modified compositor rejects minimization, restoring either axis of an
already maximized window, and interactive movement/resizing of a maximized
window. Rejected restore and minimize requests send a Wayland configure reply
so Chromium does not retain its own minimized state and stop processing input.
Fullscreen, output resizing, client-side decorations, dialogs, and popups use
the existing upstream implementation. This is a window policy, not a security
boundary or a restriction on closing tabs or the browser.

Both `labwc-browser` and the stock `labwc` used by `BROWSER_LOCK_MAXIMIZED=false`
are built from the same pinned source; Debian's `labwc` package is not installed
because it depends on Xwayland. Brave is not patched. The build disables unused
XWayland and window-icon support, enables compiler hardening, and runs upstream
tests for both binaries. No build tools enter the final image.

The complete modified Labwc source, the applied patch, its license, and the
Dockerfile build recipe are shipped in `/usr/local/share/brave-origin/labwc-source.tar.xz`.
Reversing the included patch yields the stock sources; the Dockerfile reproduces
both binaries.
