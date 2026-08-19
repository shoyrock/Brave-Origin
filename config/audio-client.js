/**
 * Standalone KasmVNC Single-Origin Web Audio & Seamless Clipboard Client
 * - Connects to the Secure Same-Origin Audio Endpoint (/audio)
 * - Decodes and renders raw stereo PCM (16-bit, 44.1kHz) with low-latency Web Audio API
 * - Enforces zero audio buffer drift and instant playback resumption on first interaction
 * - Provides native seamless bidirectional clipboard synchronization (Chromium / Firefox fallback)
 */
(function() {
    'use strict';

    window.KASM_AUDIO_TOKEN = window.KASM_AUDIO_TOKEN || '__AUDIO_SESSION_TOKEN__';

    const SAMPLE_RATE = 44100;
    const CHANNELS = 2;
    const JITTER_BUFFER_SEC = 0.03; // 30ms jitter buffer for ultra-low latency
    const MAX_BUFFER_AHEAD = 0.10;  // 100ms max buffer ahead before resetting drift

    let audioCtx = null;
    let gainNode = null;
    let ws = null;
    let nextPlayTime = 0;
    let isMuted = false;
    let volume = 1.0;
    let reconnectTimer = null;
    let isConnected = false;
    let lastPcmTime = 0;

    // --- Audio Subsystem ---

    function initAudioContext() {
        if (!audioCtx) {
            const AudioContextClass = window.AudioContext || window.webkitAudioContext;
            if (!AudioContextClass) {
                console.warn('[KasmAudio] Web Audio API is not supported in this browser.');
                return false;
            }
            audioCtx = new AudioContextClass({ sampleRate: SAMPLE_RATE });
            gainNode = audioCtx.createGain();
            gainNode.gain.value = isMuted ? 0 : volume;
            gainNode.connect(audioCtx.destination);
            nextPlayTime = audioCtx.currentTime + JITTER_BUFFER_SEC;
        }

        if (audioCtx.state === 'suspended') {
            audioCtx.resume().then(() => {
                nextPlayTime = audioCtx.currentTime + JITTER_BUFFER_SEC;
                updateUI();
            }).catch(() => {});
        }
        return true;
    }

    function createUI() {
        if (document.getElementById('kasm-audio-widget')) return;

        const widget = document.createElement('div');
        widget.id = 'kasm-audio-widget';
        widget.style.cssText = `
            position: fixed;
            bottom: 16px;
            right: 16px;
            z-index: 999999;
            display: flex;
            align-items: center;
            background: rgba(20, 24, 33, 0.88);
            backdrop-filter: blur(8px);
            border: 1px solid rgba(255, 255, 255, 0.18);
            border-radius: 24px;
            padding: 6px 14px;
            box-shadow: 0 4px 16px rgba(0, 0, 0, 0.5);
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
            font-size: 12px;
            color: #ffffff;
            user-select: none;
            transition: all 0.2s ease;
        `;

        widget.innerHTML = `
            <button id="kasm-audio-btn" style="
                background: none;
                border: none;
                color: #ffffff;
                cursor: pointer;
                padding: 4px 6px;
                display: flex;
                align-items: center;
                outline: none;
            " title="Toggle Mute / Unmute">
                <svg id="kasm-audio-icon" width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
                    <polygon points="11 5 6 9 2 9 2 15 6 15 11 5"></polygon>
                    <path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"></path>
                </svg>
            </button>
            <input type="range" id="kasm-audio-vol" min="0" max="1" step="0.05" value="1" style="
                width: 60px;
                margin-left: 6px;
                cursor: pointer;
                accent-color: #ff5500;
            " title="Audio Volume">
            <span id="kasm-audio-status" style="margin-left: 8px; font-size: 11px; color: #888888;"></span>
        `;

        document.body.appendChild(widget);

        const btn = document.getElementById('kasm-audio-btn');
        const vol = document.getElementById('kasm-audio-vol');

        btn.addEventListener('click', (e) => {
            e.stopPropagation();
            initAudioContext();
            isMuted = !isMuted;
            if (gainNode) {
                gainNode.gain.value = isMuted ? 0 : volume;
            }
            updateUI();
        });

        vol.addEventListener('input', (e) => {
            e.stopPropagation();
            initAudioContext();
            volume = parseFloat(e.target.value);
            if (volume > 0) isMuted = false;
            if (gainNode) {
                gainNode.gain.value = isMuted ? 0 : volume;
            }
            updateUI();
        });

        // Global interaction listeners in capturing phase to unlock AudioContext and Clipboard API instantly
        const userInteractionHandler = () => {
            initAudioContext();
            initSeamlessClipboard();
        };

        window.addEventListener('pointerdown', userInteractionHandler, { capture: true, passive: true });
        window.addEventListener('mousedown', userInteractionHandler, { capture: true, passive: true });
        window.addEventListener('touchstart', userInteractionHandler, { capture: true, passive: true });
        window.addEventListener('keydown', userInteractionHandler, { capture: true, passive: true });

        updateUI();
    }

    function updateUI() {
        const icon = document.getElementById('kasm-audio-icon');
        const status = document.getElementById('kasm-audio-status');
        const vol = document.getElementById('kasm-audio-vol');
        if (!icon || !status || !vol) return;

        if (isMuted || volume === 0) {
            icon.innerHTML = `
                <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon>
                <line x1="23" y1="9" x2="17" y2="15"></line>
                <line x1="17" y1="9" x2="23" y2="15"></line>
            `;
            icon.style.stroke = '#ff4444';
        } else {
            icon.innerHTML = `
                <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon>
                <path d="M19.07 4.93a10 10 0 0 1 0 14.14M15.54 8.46a5 5 0 0 1 0 7.07"></path>
            `;
            icon.style.stroke = isConnected ? '#00ff88' : '#cccccc';
        }

        if (audioCtx && audioCtx.state === 'suspended') {
            status.textContent = 'Click to enable audio';
            status.style.color = '#ffaa00';
        } else if (!isConnected) {
            status.textContent = 'Connecting...';
            status.style.color = '#888888';
        } else {
            status.textContent = '';
        }
    }

    function playPCMChunk(arrayBuffer) {
        if (!audioCtx || audioCtx.state !== 'running' || isMuted) return;

        const int16Data = new Int16Array(arrayBuffer);
        const frameCount = int16Data.length / CHANNELS;
        if (frameCount <= 0) return;

        const audioBuffer = audioCtx.createBuffer(CHANNELS, frameCount, SAMPLE_RATE);
        const leftChannel = audioBuffer.getChannelData(0);
        const rightChannel = audioBuffer.getChannelData(1);

        for (let i = 0; i < frameCount; i++) {
            leftChannel[i] = int16Data[i * 2] / 32768.0;
            rightChannel[i] = int16Data[i * 2 + 1] / 32768.0;
        }

        const source = audioCtx.createBufferSource();
        source.buffer = audioBuffer;
        source.connect(gainNode);

        const currentTime = audioCtx.currentTime;
        // Anti-drift: reset buffer position if too far ahead (e.g. background tab) or behind
        if (nextPlayTime < currentTime || nextPlayTime > currentTime + MAX_BUFFER_AHEAD) {
            nextPlayTime = currentTime + JITTER_BUFFER_SEC;
        }

        source.start(nextPlayTime);
        nextPlayTime += audioBuffer.duration;
        lastPcmTime = Date.now();
    }

    function connectWebSocket() {
        if (ws) {
            try { ws.close(); } catch (e) {}
            ws = null;
        }

        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const host = window.location.host;
        const token = window.KASM_AUDIO_TOKEN || '';
        const tokenParam = token ? `?token=${encodeURIComponent(token)}` : '';
        const url = `${protocol}//${host}/audio${tokenParam}`;

        try {
            ws = new WebSocket(url);
            ws.binaryType = 'arraybuffer';

            ws.onopen = function() {
                isConnected = true;
                updateUI();
            };

            ws.onmessage = function(event) {
                if (event.data instanceof ArrayBuffer) {
                    playPCMChunk(event.data);
                }
            };

            ws.onclose = function() {
                isConnected = false;
                updateUI();
                clearTimeout(reconnectTimer);
                reconnectTimer = setTimeout(connectWebSocket, 1500);
            };

            ws.onerror = function() {
                isConnected = false;
                updateUI();
            };
        } catch (e) {
            clearTimeout(reconnectTimer);
            reconnectTimer = setTimeout(connectWebSocket, 1500);
        }
    }

    // --- Seamless Bidirectional Clipboard Subsystem ---

    let clipboardInitialized = false;

    function initSeamlessClipboard() {
        if (clipboardInitialized) return;

        try {
            // Configure default client-side localStorage settings
            window.localStorage.setItem('clipboard_seamless', 'true');
            window.localStorage.setItem('clipboard_up', 'true');
            window.localStorage.setItem('clipboard_down', 'true');

            // Prompt permission query if available
            if (navigator.permissions && navigator.permissions.query) {
                navigator.permissions.query({ name: 'clipboard-read' }).catch(() => {});
            }

            const attachRfbClipboard = () => {
                const rfb = window.UI && window.UI.rfb;
                if (rfb) {
                    rfb.clipboardUp = true;
                    rfb.clipboardDown = true;
                    rfb.clipboardSeamless = true;
                    rfb.clipboardBinary = typeof navigator.clipboard?.read === 'function';

                    // Server -> Client: When remote X11 updates clipboard, write to local OS clipboard
                    rfb.addEventListener('clipboard', async (e) => {
                        if (e.detail && e.detail.text && navigator.clipboard && navigator.clipboard.writeText) {
                            try {
                                await navigator.clipboard.writeText(e.detail.text);
                            } catch (err) {
                                console.warn('[KasmClipboard] Remote clipboard write warning:', err);
                            }
                        }
                    });
                    clipboardInitialized = true;
                    return true;
                }
                return false;
            };

            if (!attachRfbClipboard()) {
                const checkTimer = setInterval(() => {
                    if (attachRfbClipboard()) {
                        clearInterval(checkTimer);
                    }
                }, 300);
            }

            // Client -> Server: Intercept Ctrl+V / Cmd+V in capturing phase to push local clipboard immediately
            window.addEventListener('keydown', async (e) => {
                if ((e.ctrlKey || e.metaKey) && (e.code === 'KeyV' || e.key === 'v' || e.key === 'V')) {
                    if (navigator.clipboard && navigator.clipboard.readText) {
                        try {
                            const text = await navigator.clipboard.readText();
                            if (text && text.length > 0) {
                                const rfb = window.UI && window.UI.rfb;
                                if (rfb && typeof rfb.clipboardPasteFrom === 'function') {
                                    rfb.clipboardPasteFrom(text);
                                }
                            }
                        } catch (err) {
                            // Permission or focus restriction in non-Chromium browser
                        }
                    }
                }
            }, { capture: true, passive: true });

        } catch (e) {
            console.warn('[KasmClipboard] Init warning:', e);
        }
    }

    // Initialize UI, audio, and clipboard when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => {
            createUI();
            connectWebSocket();
            initSeamlessClipboard();
        });
    } else {
        createUI();
        connectWebSocket();
        initSeamlessClipboard();
    }
})();
