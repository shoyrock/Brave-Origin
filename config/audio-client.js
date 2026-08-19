/**
 * Standalone KasmVNC Single-Origin Web Audio Client
 * Connects to the Secure Same-Origin Audio Endpoint (/audio)
 * Decodes and renders raw stereo PCM (16-bit, 44.1kHz) with low-latency Web Audio API.
 */
(function() {
    'use strict';

    const SAMPLE_RATE = 44100;
    const CHANNELS = 2;
    const JITTER_BUFFER_SEC = 0.05; // 50ms initial jitter buffer

    let audioCtx = null;
    let gainNode = null;
    let ws = null;
    let nextPlayTime = 0;
    let isMuted = false;
    let volume = 1.0;
    let reconnectTimer = null;
    let isConnected = false;

    function initAudioContext() {
        if (!audioCtx) {
            const AudioContextClass = window.AudioContext || window.webkitAudioContext;
            if (!AudioContextClass) {
                console.warn('[KasmAudio] Web Audio API is not supported in this browser.');
                return false;
            }
            audioCtx = new AudioContextClass({ sampleRate: SAMPLE_RATE });
            gainNode = audioCtx.createGain();
            gainNode.gain.value = volume;
            gainNode.connect(audioCtx.destination);
        }
        if (audioCtx.state === 'suspended') {
            audioCtx.resume().then(() => {
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
            background: rgba(20, 24, 33, 0.85);
            backdrop-filter: blur(8px);
            border: 1px solid rgba(255, 255, 255, 0.15);
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
                    <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon>
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

        // Resume on any user interaction with the page or desktop canvas
        const resumeHandler = () => {
            initAudioContext();
            window.removeEventListener('pointerdown', resumeHandler);
            window.removeEventListener('keydown', resumeHandler);
        };
        window.addEventListener('pointerdown', resumeHandler);
        window.addEventListener('keydown', resumeHandler);

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
            status.textContent = 'Click to enable';
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
        if (nextPlayTime < currentTime) {
            nextPlayTime = currentTime + JITTER_BUFFER_SEC;
        }

        source.start(nextPlayTime);
        nextPlayTime += audioBuffer.duration;
    }

    function connectWebSocket() {
        if (ws) {
            try { ws.close(); } catch (e) {}
            ws = null;
        }

        const protocol = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
        const host = window.location.host; // Contains hostname:port (e.g. 192.168.10.10:8443 or my-host:8443)
        const token = window.KASM_AUDIO_TOKEN || '';
        const tokenParam = token ? `?token=${encodeURIComponent(token)}` : '';
        const url = `${protocol}//${host}/audio${tokenParam}`;

        console.log(`[KasmAudio] Connecting to Audio Relay at ${url}...`);

        try {
            ws = new WebSocket(url);
            ws.binaryType = 'arraybuffer';

            ws.onopen = function() {
                console.log('[KasmAudio] Audio WebSocket connected successfully.');
                isConnected = true;
                updateUI();
            };

            ws.onmessage = function(event) {
                if (event.data instanceof ArrayBuffer) {
                    playPCMChunk(event.data);
                }
            };

            ws.onclose = function(e) {
                console.log('[KasmAudio] Audio WebSocket closed. Reconnecting in 3s...', e.reason);
                isConnected = false;
                updateUI();
                clearTimeout(reconnectTimer);
                reconnectTimer = setTimeout(connectWebSocket, 3000);
            };

            ws.onerror = function(err) {
                console.warn('[KasmAudio] Audio WebSocket error:', err);
                isConnected = false;
                updateUI();
            };
        } catch (e) {
            console.error('[KasmAudio] Failed to initialize WebSocket:', e);
            clearTimeout(reconnectTimer);
            reconnectTimer = setTimeout(connectWebSocket, 3000);
        }
    }

    // Initialize when DOM is ready
    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', () => {
            createUI();
            connectWebSocket();
        });
    } else {
        createUI();
        connectWebSocket();
    }
})();
