/**
 * Standalone KasmVNC Seamless Bidirectional Clipboard Client
 * - Provides reliable local -> remote and remote -> local clipboard synchronization
 * - Solves async race condition by ensuring local clipboard text is delivered to X11 before paste keystroke
 * - Automatically retries remote clipboard writes upon focus/user interaction
 * - 100% independent from audio subsystem and ENABLE_AUDIO flag
 */
(function() {
    'use strict';

    let isInitialized = false;
    let pendingRemoteClipboard = null;
    let isPasting = false;

    const XK_Control_L = 65507;
    const XK_v = 118;

    function getRfb() {
        return window.UI && window.UI.rfb;
    }

    function initClipboardSettings() {
        try {
            window.localStorage.setItem('clipboard_seamless', 'true');
            window.localStorage.setItem('clipboard_up', 'true');
            window.localStorage.setItem('clipboard_down', 'true');
        } catch (e) {}

        if (navigator.permissions && navigator.permissions.query) {
            navigator.permissions.query({ name: 'clipboard-read' }).catch(() => {});
            navigator.permissions.query({ name: 'clipboard-write' }).catch(() => {});
        }
    }

    function flushPendingRemoteClipboard() {
        if (pendingRemoteClipboard && navigator.clipboard && navigator.clipboard.writeText) {
            const textToWrite = pendingRemoteClipboard;
            navigator.clipboard.writeText(textToWrite).then(() => {
                if (pendingRemoteClipboard === textToWrite) {
                    pendingRemoteClipboard = null;
                }
            }).catch(() => {});
        }
    }

    function attachRfbListeners() {
        const rfb = getRfb();
        if (!rfb || isInitialized) return !!rfb;

        rfb.clipboardUp = true;
        rfb.clipboardDown = true;
        rfb.clipboardSeamless = true;
        rfb.clipboardBinary = typeof navigator.clipboard?.read === 'function';

        // Remote -> Local: Listen for X11 clipboard broadcasts from server
        rfb.addEventListener('clipboard', (e) => {
            const text = e.detail && e.detail.text;
            if (typeof text === 'string' && text.length > 0) {
                pendingRemoteClipboard = text;
                if (navigator.clipboard && navigator.clipboard.writeText) {
                    navigator.clipboard.writeText(text).then(() => {
                        if (pendingRemoteClipboard === text) {
                            pendingRemoteClipboard = null;
                        }
                    }).catch(() => {
                        // Will be flushed on next focus/click event
                    });
                }
            }
        });

        isInitialized = true;
        return true;
    }

    async function handleLocalToRemotePaste(e) {
        const rfb = getRfb();
        if (!rfb || isPasting) return;

        // Obtain local clipboard text
        let clipboardText = '';
        if (e && e.clipboardData) {
            clipboardText = e.clipboardData.getData('text/plain') || '';
        }

        if (!clipboardText && navigator.clipboard && navigator.clipboard.readText) {
            try {
                clipboardText = await navigator.clipboard.readText();
            } catch (err) {
                return;
            }
        }

        if (typeof clipboardText !== 'string' || clipboardText.length === 0) {
            return;
        }

        // Prevent duplicate simultaneous paste events
        isPasting = true;

        try {
            // Step 1: Push fresh clipboard text to KasmVNC / X11
            if (typeof rfb.clipboardPasteFrom === 'function') {
                rfb.clipboardPasteFrom(clipboardText);
            }

            // Step 2: Dispatch remote Ctrl+V keystroke sequentially to trigger X11 paste
            const keyboard = rfb._keyboard;
            if (keyboard && typeof keyboard._sendKeyEvent === 'function') {
                keyboard._sendKeyEvent(XK_Control_L, 'ControlLeft', true);
                keyboard._sendKeyEvent(XK_v, 'KeyV', true);
                keyboard._sendKeyEvent(XK_v, 'KeyV', false);
                keyboard._sendKeyEvent(XK_Control_L, 'ControlLeft', false);
            }
        } finally {
            setTimeout(() => {
                isPasting = false;
            }, 100);
        }
    }

    // Intercept Ctrl+V / Cmd+V in capture phase
    window.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && !e.altKey && (e.code === 'KeyV' || e.key === 'v' || e.key === 'V')) {
            const rfb = getRfb();
            if (rfb && rfb._rfbConnectionState === 'connected') {
                // Prevent KasmVNC default premature key send
                e.stopPropagation();
                e.stopImmediatePropagation();
                e.preventDefault();

                handleLocalToRemotePaste(e);
            }
        }
    }, { capture: true });

    // Handle native browser paste events
    window.addEventListener('paste', (e) => {
        const rfb = getRfb();
        if (rfb && rfb._rfbConnectionState === 'connected') {
            e.stopPropagation();
            e.stopImmediatePropagation();
            e.preventDefault();

            handleLocalToRemotePaste(e);
        }
    }, { capture: true });

    // Focus and user interaction handlers for pending clipboard writes
    window.addEventListener('focus', flushPendingRemoteClipboard, { passive: true });
    window.addEventListener('pointerdown', flushPendingRemoteClipboard, { capture: true, passive: true });
    window.addEventListener('mousedown', flushPendingRemoteClipboard, { capture: true, passive: true });
    document.addEventListener('visibilitychange', () => {
        if (document.visibilityState === 'visible') {
            flushPendingRemoteClipboard();
        }
    }, { passive: true });

    // Poll for RFB object readiness
    initClipboardSettings();
    if (!attachRfbListeners()) {
        const pollInterval = setInterval(() => {
            if (attachRfbListeners()) {
                clearInterval(pollInterval);
            }
        }, 200);
    }
})();
