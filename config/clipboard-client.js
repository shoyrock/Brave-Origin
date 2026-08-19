/**
 * Standalone KasmVNC Seamless Bidirectional Clipboard Client with Live Diagnostics
 * - Provides single consolidated path for local -> remote and remote -> local clipboard synchronization
 * - Prioritizes trusted native paste event with synchronous clipboardData
 * - Graceful fallback to navigator.clipboard.readText() when paste event is unhandled
 * - Automatically retries remote -> local writeText on focus/interaction
 * - Live diagnostic HUD and window.KASM_CLIPBOARD_LOG for real-client verification
 * - 100% independent from audio subsystem and ENABLE_AUDIO flag
 */
(function() {
    'use strict';

    window.BRAVE_ORIGIN_CLIENT_BUILD = window.BRAVE_ORIGIN_CLIENT_BUILD || '__BUILD_COMMIT__';
    window.KASM_CLIPBOARD_LOG = window.KASM_CLIPBOARD_LOG || [];

    const XK_Control_L = 65507;
    const XK_v = 118;

    let isRfbInitialized = false;
    let pendingRemoteClipboard = null;
    let lastPasteTime = 0;
    let isPasting = false;
    let clipboardStatus = 'Initializing';

    function logEvent(name, data = {}) {
        const entry = {
            time: new Date().toISOString().substring(11, 23),
            event: name,
            ...data
        };
        window.KASM_CLIPBOARD_LOG.push(entry);
        if (window.KASM_CLIPBOARD_LOG.length > 200) {
            window.KASM_CLIPBOARD_LOG.shift();
        }
        console.log(`[KasmClipboard] [${entry.time}] ${name}:`, data);
        updateDiagnosticHUD();
    }

    function getRfb() {
        return window.UI && window.UI.rfb;
    }

    function updateStatus(status) {
        clipboardStatus = status;
        updateDiagnosticHUD();
    }

    function createDiagnosticHUD() {
        if (document.getElementById('kasm-diag-hud')) return;

        const hud = document.createElement('div');
        hud.id = 'kasm-diag-hud';
        hud.style.cssText = `
            position: fixed;
            bottom: 16px;
            left: 16px;
            z-index: 999998;
            display: flex;
            flex-direction: column;
            background: rgba(15, 20, 28, 0.90);
            backdrop-filter: blur(8px);
            border: 1px solid rgba(255, 255, 255, 0.15);
            border-radius: 12px;
            padding: 8px 12px;
            box-shadow: 0 4px 16px rgba(0, 0, 0, 0.6);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, monospace;
            font-size: 11px;
            color: #d1d5db;
            user-select: none;
            max-width: 480px;
            transition: all 0.2s ease;
        `;

        hud.innerHTML = `
            <div style="display: flex; align-items: center; justify-content: space-between; gap: 8px;">
                <span id="kasm-clip-badge" style="color: #60a5fa; font-weight: 600;">Clipboard: Initializing...</span>
                <span style="color: #6b7280; font-size: 10px;">Build: <code style="color: #9ca3af;">${(window.BRAVE_ORIGIN_CLIENT_BUILD || 'dev').substring(0, 7)}</code></span>
                <button id="kasm-diag-toggle" style="
                    background: rgba(255, 255, 255, 0.1);
                    border: none;
                    color: #9ca3af;
                    border-radius: 4px;
                    padding: 2px 6px;
                    cursor: pointer;
                    font-size: 10px;
                ">Logs</button>
            </div>
            <div id="kasm-diag-log-container" style="display: none; margin-top: 8px; border-top: 1px solid rgba(255, 255, 255, 0.1); padding-top: 6px; max-height: 160px; overflow-y: auto;">
                <pre id="kasm-diag-log-content" style="margin: 0; font-size: 10px; line-height: 1.3; color: #93c5fd; white-space: pre-wrap; word-break: break-all;"></pre>
            </div>
        `;

        document.body.appendChild(hud);

        const toggleBtn = document.getElementById('kasm-diag-toggle');
        const logContainer = document.getElementById('kasm-diag-log-container');
        if (toggleBtn && logContainer) {
            toggleBtn.addEventListener('click', (e) => {
                e.stopPropagation();
                const isHidden = logContainer.style.display === 'none';
                logContainer.style.display = isHidden ? 'block' : 'none';
                toggleBtn.textContent = isHidden ? 'Hide' : 'Logs';
                updateDiagnosticHUD();
            });
        }
    }

    function updateDiagnosticHUD() {
        const badge = document.getElementById('kasm-clip-badge');
        if (badge) {
            badge.textContent = `Clipboard: ${clipboardStatus}`;
            if (clipboardStatus.includes('Ready') || clipboardStatus.includes('OK') || clipboardStatus.includes('Synced')) {
                badge.style.color = '#34d399';
            } else if (clipboardStatus.includes('Blocked') || clipboardStatus.includes('Error')) {
                badge.style.color = '#f87171';
            } else if (clipboardStatus.includes('Waiting') || clipboardStatus.includes('Focus')) {
                badge.style.color = '#fbbf24';
            } else {
                badge.style.color = '#60a5fa';
            }
        }

        const logContent = document.getElementById('kasm-diag-log-content');
        if (logContent && document.getElementById('kasm-diag-log-container')?.style.display !== 'none') {
            const recent = window.KASM_CLIPBOARD_LOG.slice(-15);
            logContent.textContent = recent.map(r => `[${r.time}] ${r.event}: ${JSON.stringify(r).replace(/^{|}$|"time":[^,]*,/g, '')}`).join('\n');
            logContent.scrollTop = logContent.scrollHeight;
        }
    }

    function checkPermissions() {
        if (navigator.permissions && navigator.permissions.query) {
            navigator.permissions.query({ name: 'clipboard-read' }).then(res => {
                logEvent('perm_clipboard_read', { state: res.state });
                res.onchange = () => {
                    logEvent('perm_clipboard_read_change', { state: res.state });
                };
            }).catch(err => {
                logEvent('perm_clipboard_read_unsupported', { error: err.name });
            });

            navigator.permissions.query({ name: 'clipboard-write' }).then(res => {
                logEvent('perm_clipboard_write', { state: res.state });
            }).catch(() => {});
        }
    }

    function flushPendingRemoteClipboard(reason) {
        if (!pendingRemoteClipboard) return;

        if (navigator.clipboard && navigator.clipboard.writeText) {
            const textToSync = pendingRemoteClipboard;
            logEvent('writeText_start', { reason, length: textToSync.length });
            navigator.clipboard.writeText(textToSync).then(() => {
                logEvent('writeText_success', { length: textToSync.length });
                if (pendingRemoteClipboard === textToSync) {
                    pendingRemoteClipboard = null;
                }
                updateStatus('Ready (Remote Synced)');
            }).catch(err => {
                logEvent('writeText_failure', { error_name: err.name, message: err.message });
                updateStatus(`Waiting for focus to sync (${err.name})`);
            });
        }
    }

    function attachRfbListeners() {
        const rfb = getRfb();
        if (!rfb || isRfbInitialized) return !!rfb;

        try {
            // Configure RFB clipboard state
            rfb.clipboardUp = true;
            rfb.clipboardDown = true;
            rfb.clipboardSeamless = true;
            rfb.clipboardBinary = typeof navigator.clipboard?.read === 'function';

            logEvent('rfb_attached', {
                clipboardUp: rfb.clipboardUp,
                clipboardDown: rfb.clipboardDown,
                clipboardSeamless: rfb.clipboardSeamless,
                clipboardBinary: rfb.clipboardBinary
            });

            // Remote -> Local: Server X11 clipboard broadcasts
            rfb.addEventListener('clipboard', (e) => {
                const text = e.detail && e.detail.text;
                if (typeof text === 'string' && text.length > 0) {
                    logEvent('server_clipboard_event', { length: text.length });
                    pendingRemoteClipboard = text;
                    flushPendingRemoteClipboard('server_clipboard_event');
                }
            });

            isRfbInitialized = true;
            updateStatus('Ready (Seamless Active)');
            return true;
        } catch (e) {
            logEvent('rfb_attach_error', { error: e.message });
            return false;
        }
    }

    // Consolidated Local -> Remote Paste Function
    async function executeLocalToRemotePaste(source, rawText) {
        const rfb = getRfb();
        if (!rfb || rfb._rfbConnectionState !== 'connected') {
            logEvent('paste_aborted', { reason: 'rfb_not_connected' });
            return false;
        }

        if (isPasting && Date.now() - lastPasteTime < 150) {
            logEvent('paste_throttled', { reason: 'duplicate_in_progress' });
            return false;
        }

        let clipboardText = rawText;

        // If rawText was not provided (e.g. keydown fallback), fetch asynchronously
        if (!clipboardText && navigator.clipboard && navigator.clipboard.readText) {
            logEvent('readText_start', { source });
            try {
                clipboardText = await navigator.clipboard.readText();
                logEvent('readText_success', { length: clipboardText ? clipboardText.length : 0 });
            } catch (err) {
                logEvent('readText_failure', { error_name: err.name, message: err.message });
                updateStatus(`Browser blocked read (${err.name})`);
                // Fallback: forward raw Ctrl+V keysym so user can still trigger X11 paste
                dispatchRemoteCtrlV(rfb, 'raw_fallback');
                return false;
            }
        }

        if (typeof clipboardText !== 'string' || clipboardText.length === 0) {
            logEvent('paste_empty_text', { source });
            return false;
        }

        isPasting = true;
        lastPasteTime = Date.now();

        try {
            // 1. Send clipboard content packet to RFB / X11
            logEvent('clipboardPasteFrom_call', { source, length: clipboardText.length });
            if (typeof rfb.clipboardPasteFrom === 'function') {
                rfb.clipboardPasteFrom(clipboardText);
            }

            // 2. Dispatch remote Ctrl+V keystrokes in FIFO sequence to trigger X11 paste
            dispatchRemoteCtrlV(rfb, source);
            updateStatus('Pasted (Synced)');
            return true;
        } catch (err) {
            logEvent('paste_execution_error', { error: err.message });
            return false;
        } finally {
            setTimeout(() => {
                isPasting = false;
            }, 100);
        }
    }

    function dispatchRemoteCtrlV(rfb, source) {
        logEvent('remote_key_dispatch_start', { source });
        const keyboard = rfb._keyboard;
        if (keyboard && typeof keyboard._sendKeyEvent === 'function') {
            keyboard._sendKeyEvent(XK_Control_L, 'ControlLeft', true);
            keyboard._sendKeyEvent(XK_v, 'KeyV', true);
            keyboard._sendKeyEvent(XK_v, 'KeyV', false);
            keyboard._sendKeyEvent(XK_Control_L, 'ControlLeft', false);
            logEvent('remote_key_dispatch_complete', { source });
        }
    }

    // 1. Primary Handler: Trusted Native "paste" Event
    window.addEventListener('paste', (e) => {
        const rfb = getRfb();
        if (!rfb || rfb._rfbConnectionState !== 'connected') return;

        const hasClipboardData = !!(e.clipboardData && typeof e.clipboardData.getData === 'function');
        const text = hasClipboardData ? e.clipboardData.getData('text/plain') : '';

        logEvent('paste_event', {
            isTrusted: e.isTrusted,
            hasClipboardData,
            length: text ? text.length : 0
        });

        if (text && text.length > 0) {
            e.stopPropagation();
            e.stopImmediatePropagation();
            e.preventDefault();

            executeLocalToRemotePaste('native_paste_event', text);
        }
    }, { capture: true });

    // 2. Secondary Handler: Capture-phase KeyDown for Ctrl+V / Cmd+V
    window.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && !e.altKey && (e.code === 'KeyV' || e.key === 'v' || e.key === 'V')) {
            const rfb = getRfb();
            if (!rfb || rfb._rfbConnectionState !== 'connected') return;

            logEvent('keydown_ctrl_v', {
                isTrusted: e.isTrusted,
                code: e.code,
                key: e.key,
                ctrlKey: e.ctrlKey,
                metaKey: e.metaKey
            });

            // Prevent KasmVNC default handler from sending an out-of-order raw Ctrl+V
            e.stopPropagation();
            e.stopImmediatePropagation();
            e.preventDefault();

            executeLocalToRemotePaste('keydown_gesture', null);
        }
    }, { capture: true });

    // 3. Focus & Visibility Change Handlers
    window.addEventListener('focus', () => {
        logEvent('window_focus', { hasFocus: document.hasFocus(), visibility: document.visibilityState });
        flushPendingRemoteClipboard('window_focus');
    }, { passive: true });

    window.addEventListener('blur', () => {
        logEvent('window_blur', { hasFocus: document.hasFocus() });
    }, { passive: true });

    document.addEventListener('visibilitychange', () => {
        logEvent('visibilitychange', { state: document.visibilityState });
        if (document.visibilityState === 'visible') {
            flushPendingRemoteClipboard('visibility_visible');
        }
    }, { passive: true });

    window.addEventListener('pointerdown', () => {
        flushPendingRemoteClipboard('pointerdown');
    }, { capture: true, passive: true });

    // Initialize UI and RFB listener
    function init() {
        createDiagnosticHUD();
        checkPermissions();
        if (!attachRfbListeners()) {
            const pollTimer = setInterval(() => {
                if (attachRfbListeners()) {
                    clearInterval(pollTimer);
                }
            }, 200);
        }
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
