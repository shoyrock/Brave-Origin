/**
 * Standalone KasmVNC Seamless Bidirectional Clipboard Client
 * 
 * Guarantees:
 * 1. 100% independent from audio subsystem and ENABLE_AUDIO flag
 * 2. Exactly one authoritative execution path per user action (native paste event with microtask fallback)
 * 3. Idempotent initialization guard (window.__BRAVE_ORIGIN_CLIPBOARD_INITIALIZED__)
 * 4. Key-repeat duplicate protection (ignores e.repeat)
 * 5. Modifier key release safety (try/finally on remote key dispatch)
 * 6. Dynamic RFB resolution on reconnects without leaking DOM listeners
 * 7. Deduplicated remote -> local copy writes (prevents redundant writes on focus/click)
 */
(function() {
    'use strict';

    if (window.__BRAVE_ORIGIN_CLIPBOARD_INITIALIZED__) {
        return;
    }
    window.__BRAVE_ORIGIN_CLIPBOARD_INITIALIZED__ = true;

    window.BRAVE_ORIGIN_CLIENT_BUILD = window.BRAVE_ORIGIN_CLIENT_BUILD || '__BUILD_COMMIT__';
    window.KASM_CLIPBOARD_LOG = window.KASM_CLIPBOARD_LOG || [];

    const XK_Control_L = 65507;
    const XK_v = 118;

    let attachedRfb = null;
    let pendingRemoteText = null;
    let lastWrittenRemoteText = null;
    let isWritingRemoteText = false;
    let activeGestureId = 0;
    let gestureHandled = false;
    let fallbackTimer = null;
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
        updateDiagnosticHUD();
    }

    function getCurrentRfb() {
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

    function onRemoteClipboard(e) {
        const text = e.detail && e.detail.text;
        if (typeof text === 'string' && text.length > 0) {
            if (text === lastWrittenRemoteText) {
                return; // Already present in local clipboard
            }
            logEvent('server_clipboard_event', { length: text.length });
            pendingRemoteText = text;
            flushPendingRemoteClipboard('server_clipboard_event');
        }
    }

    function flushPendingRemoteClipboard(reason) {
        if (!pendingRemoteText || isWritingRemoteText || pendingRemoteText === lastWrittenRemoteText) {
            return;
        }

        if (navigator.clipboard && navigator.clipboard.writeText) {
            const textToSync = pendingRemoteText;
            isWritingRemoteText = true;
            logEvent('writeText_start', { reason, length: textToSync.length });

            navigator.clipboard.writeText(textToSync).then(() => {
                logEvent('writeText_success', { length: textToSync.length });
                lastWrittenRemoteText = textToSync;
                if (pendingRemoteText === textToSync) {
                    pendingRemoteText = null;
                }
                updateStatus('Ready (Remote Synced)');
            }).catch(err => {
                logEvent('writeText_failure', { error_name: err.name, message: err.message });
                updateStatus(`Waiting for focus to sync (${err.name})`);
            }).finally(() => {
                isWritingRemoteText = false;
            });
        }
    }

    function ensureRfbAttached() {
        const rfb = getCurrentRfb();
        if (!rfb || rfb === attachedRfb) return !!attachedRfb;

        try {
            if (attachedRfb && typeof attachedRfb.removeEventListener === 'function') {
                try { attachedRfb.removeEventListener('clipboard', onRemoteClipboard); } catch(e) {}
            }

            rfb.clipboardUp = true;
            rfb.clipboardDown = true;
            rfb.clipboardSeamless = true;
            rfb.clipboardBinary = typeof navigator.clipboard?.read === 'function';

            rfb.addEventListener('clipboard', onRemoteClipboard);
            attachedRfb = rfb;

            logEvent('rfb_attached', {
                state: rfb._rfbConnectionState,
                clipboardSeamless: rfb.clipboardSeamless
            });
            updateStatus('Ready (Seamless Active)');
            return true;
        } catch (e) {
            logEvent('rfb_attach_error', { error: e.message });
            return false;
        }
    }

    function dispatchRemoteCtrlV(rfb, source) {
        const keyboard = rfb && rfb._keyboard;
        if (!keyboard || typeof keyboard._sendKeyEvent !== 'function') return;

        logEvent('remote_key_dispatch_start', { source });
        try {
            keyboard._sendKeyEvent(XK_Control_L, 'ControlLeft', true);
            keyboard._sendKeyEvent(XK_v, 'KeyV', true);
        } finally {
            keyboard._sendKeyEvent(XK_v, 'KeyV', false);
            keyboard._sendKeyEvent(XK_Control_L, 'ControlLeft', false);
            logEvent('remote_key_dispatch_complete', { source });
        }
    }

    async function executeLocalToRemotePaste(source, rawText) {
        ensureRfbAttached();
        const rfb = getCurrentRfb();
        if (!rfb || rfb._rfbConnectionState !== 'connected') {
            logEvent('paste_aborted', { reason: 'rfb_not_connected' });
            return false;
        }

        if (isPasting) {
            logEvent('paste_throttled', { reason: 'paste_in_progress' });
            return false;
        }

        let clipboardText = rawText;

        if (!clipboardText && navigator.clipboard && navigator.clipboard.readText) {
            logEvent('readText_start', { source });
            try {
                clipboardText = await navigator.clipboard.readText();
                logEvent('readText_success', { length: clipboardText ? clipboardText.length : 0 });
            } catch (err) {
                logEvent('readText_failure', { error_name: err.name, message: err.message });
                updateStatus(`Browser blocked read (${err.name})`);
                dispatchRemoteCtrlV(rfb, 'raw_fallback');
                return false;
            }
        }

        if (typeof clipboardText !== 'string' || clipboardText.length === 0) {
            logEvent('paste_empty_text', { source });
            return false;
        }

        isPasting = true;

        try {
            logEvent('clipboardPasteFrom_call', { source, length: clipboardText.length });
            if (typeof rfb.clipboardPasteFrom === 'function') {
                rfb.clipboardPasteFrom(clipboardText);
            }
            dispatchRemoteCtrlV(rfb, source);
            updateStatus('Pasted (Synced)');
            return true;
        } catch (err) {
            logEvent('paste_execution_error', { error: err.message });
            return false;
        } finally {
            setTimeout(() => {
                isPasting = false;
            }, 80);
        }
    }

    // 1. Primary Handler: Trusted Native "paste" Event
    window.addEventListener('paste', (e) => {
        ensureRfbAttached();
        const rfb = getCurrentRfb();
        if (!rfb || rfb._rfbConnectionState !== 'connected') return;

        const hasClipboardData = !!(e.clipboardData && typeof e.clipboardData.getData === 'function');
        const text = hasClipboardData ? e.clipboardData.getData('text/plain') : '';

        logEvent('paste_event', {
            isTrusted: e.isTrusted,
            hasClipboardData,
            length: text ? text.length : 0
        });

        if (text && text.length > 0) {
            gestureHandled = true;
            if (fallbackTimer) {
                clearTimeout(fallbackTimer);
                fallbackTimer = null;
            }

            e.stopPropagation();
            e.stopImmediatePropagation();
            e.preventDefault();

            executeLocalToRemotePaste('native_paste_event', text);
        }
    }, { capture: true });

    // 2. Secondary Handler: KeyDown with Fallback Timer (Only runs if native paste event does not fire)
    window.addEventListener('keydown', (e) => {
        if ((e.ctrlKey || e.metaKey) && !e.altKey && (e.code === 'KeyV' || e.key === 'v' || e.key === 'V')) {
            if (e.repeat) {
                // Ignore key repeat to prevent duplicate remote paste operations
                return;
            }

            ensureRfbAttached();
            const rfb = getCurrentRfb();
            if (!rfb || rfb._rfbConnectionState !== 'connected') return;

            const gestureId = ++activeGestureId;
            gestureHandled = false;

            logEvent('keydown_ctrl_v', {
                gestureId,
                isTrusted: e.isTrusted,
                code: e.code
            });

            // Prevent KasmVNC default handler from sending an un-synchronized raw Ctrl+V keystroke
            e.stopImmediatePropagation();

            // Schedule fallback timer: only executes if native paste event did not handle this gesture
            if (fallbackTimer) clearTimeout(fallbackTimer);
            fallbackTimer = setTimeout(async () => {
                fallbackTimer = null;
                if (gestureId !== activeGestureId || gestureHandled) {
                    return; // Successfully handled by native paste event
                }
                gestureHandled = true;
                logEvent('fallback_timer_fired', { gestureId });
                await executeLocalToRemotePaste('fallback_keydown', null);
            }, 35);
        }
    }, { capture: true });

    // 3. Focus & Visibility Change Handlers
    window.addEventListener('focus', () => {
        logEvent('window_focus', { hasFocus: document.hasFocus(), visibility: document.visibilityState });
        ensureRfbAttached();
        flushPendingRemoteClipboard('window_focus');
    }, { passive: true });

    window.addEventListener('blur', () => {
        logEvent('window_blur', { hasFocus: document.hasFocus() });
    }, { passive: true });

    document.addEventListener('visibilitychange', () => {
        logEvent('visibilitychange', { state: document.visibilityState });
        if (document.visibilityState === 'visible') {
            ensureRfbAttached();
            flushPendingRemoteClipboard('visibility_visible');
        }
    }, { passive: true });

    window.addEventListener('pointerdown', () => {
        ensureRfbAttached();
        flushPendingRemoteClipboard('pointerdown');
    }, { capture: true, passive: true });

    // 4. Initialization
    function init() {
        createDiagnosticHUD();
        checkPermissions();
        ensureRfbAttached();
        setInterval(ensureRfbAttached, 1000);
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
