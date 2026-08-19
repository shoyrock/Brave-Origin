/**
 * Standalone KasmVNC Single-Origin Web Audio Client with Live Diagnostics
 * - Connects to the Secure Same-Origin Audio Endpoint (/audio)
 * - Decodes and renders raw stereo PCM (16-bit, 44.1kHz) with low-latency Web Audio API
 * - Enforces zero audio backlog while suspended and instant playback on first interaction
 * - Exposes window.KASM_AUDIO_LOG for real-client browser timing analysis
 * - 100% independent from clipboard subsystem
 */
(function() {
    'use strict';

    window.KASM_AUDIO_TOKEN = window.KASM_AUDIO_TOKEN || '__AUDIO_SESSION_TOKEN__';
    window.KASM_AUDIO_LOG = window.KASM_AUDIO_LOG || [];

    const SAMPLE_RATE = 44100;
    const CHANNELS = 2;
    const JITTER_BUFFER_SEC = 0.03; // 30ms jitter buffer for ultra-low latency
    const MAX_BUFFER_AHEAD = 0.09;  // 90ms max buffer ahead before anti-drift reset

    let audioCtx = null;
    let gainNode = null;
    let ws = null;
    let nextPlayTime = 0;
    let isMuted = false;
    let volume = 1.0;
    let reconnectTimer = null;
    let isConnected = false;
    let isPlaying = false;
    let lastPcmTime = 0;
    let pcmWatchdogTimer = null;
    let hasReceivedFirstPcm = false;
    let hasScheduledFirstBuffer = false;

    function logAudioEvent(name, data = {}) {
        const entry = {
            time: new Date().toISOString().substring(11, 23),
            event: name,
            audioCtx_state: audioCtx ? audioCtx.state : 'null',
            ...data
        };
        window.KASM_AUDIO_LOG.push(entry);
        if (window.KASM_AUDIO_LOG.length > 200) {
            window.KASM_AUDIO_LOG.shift();
        }
        console.log(`[KasmAudio] [${entry.time}] ${name}:`, data);
    }

    function initAudioContext() {
        if (!audioCtx) {
            const AudioContextClass = window.AudioContext || window.webkitAudioContext;
            if (!AudioContextClass) {
                console.warn('[KasmAudio] Web Audio API is not supported in this browser.');
                logAudioEvent('audio_unsupported');
                return false;
            }
            audioCtx = new AudioContextClass({ sampleRate: SAMPLE_RATE });
            gainNode = audioCtx.createGain();
            gainNode.gain.value = isMuted ? 0 : volume;
            gainNode.connect(audioCtx.destination);
            nextPlayTime = audioCtx.currentTime + JITTER_BUFFER_SEC;
            logAudioEvent('audioCtx_created', { state: audioCtx.state, sampleRate: audioCtx.sampleRate });
        }

        if (audioCtx.state === 'suspended') {
            const t0 = performance.now();
            logAudioEvent('audioCtx_resume_call');
            audioCtx.resume().then(() => {
                const dur = Math.round(performance.now() - t0);
                nextPlayTime = audioCtx.currentTime + JITTER_BUFFER_SEC;
                logAudioEvent('audioCtx_running', { resume_duration_ms: dur });
                updateUI();
            }).catch(err => {
                logAudioEvent('audioCtx_resume_error', { error: err.message });
            });
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
            logAudioEvent('audio_toggle_mute', { isMuted });
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

        // Global interaction listeners in capturing phase to unlock AudioContext on first gesture
        const userInteractionHandler = (e) => {
            logAudioEvent('user_interaction', { type: e.type });
            initAudioContext();
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
        } else if (isPlaying) {
            status.textContent = '';
        } else {
            status.textContent = '';
        }
    }

    function playPCMChunk(arrayBuffer) {
        // Drop incoming audio while suspended to avoid stale backlog
        if (!audioCtx || audioCtx.state !== 'running' || isMuted) {
            if (!hasReceivedFirstPcm) {
                logAudioEvent('first_pcm_frame_dropped_suspended', { bytes: arrayBuffer.byteLength });
                hasReceivedFirstPcm = true;
            }
            return;
        }

        const int16Data = new Int16Array(arrayBuffer);
        const frameCount = int16Data.length / CHANNELS;
        if (frameCount <= 0) return;

        if (!hasReceivedFirstPcm) {
            logAudioEvent('first_pcm_frame_received', { bytes: arrayBuffer.byteLength });
            hasReceivedFirstPcm = true;
        }

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
        // Anti-drift: Clamp nextPlayTime if behind or too far ahead
        if (nextPlayTime < currentTime || nextPlayTime > currentTime + MAX_BUFFER_AHEAD) {
            const driftLead = Math.round((nextPlayTime - currentTime) * 1000);
            logAudioEvent('schedule_reset_antidrift', { drift_lead_ms: driftLead });
            nextPlayTime = currentTime + JITTER_BUFFER_SEC;
        }

        source.start(nextPlayTime);
        nextPlayTime += audioBuffer.duration;
        lastPcmTime = Date.now();

        if (!hasScheduledFirstBuffer) {
            logAudioEvent('first_pcm_buffer_scheduled', {
                currentTime: Math.round(currentTime * 1000) / 1000,
                scheduledTime: Math.round(nextPlayTime * 1000) / 1000
            });
            hasScheduledFirstBuffer = true;
        }

        if (!isPlaying) {
            isPlaying = true;
            updateUI();
        }
    }

    function startPcmWatchdog() {
        if (pcmWatchdogTimer) clearInterval(pcmWatchdogTimer);
        pcmWatchdogTimer = setInterval(() => {
            if (isPlaying && Date.now() - lastPcmTime > 1000) {
                isPlaying = false;
                updateUI();
            }
        }, 500);
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

        logAudioEvent('ws_connect_start', { url });

        try {
            ws = new WebSocket(url);
            ws.binaryType = 'arraybuffer';

            ws.onopen = function() {
                logAudioEvent('ws_open');
                isConnected = true;
                updateUI();
            };

            ws.onmessage = function(event) {
                if (event.data instanceof ArrayBuffer) {
                    playPCMChunk(event.data);
                }
            };

            ws.onclose = function(e) {
                logAudioEvent('ws_close', { code: e.code, reason: e.reason });
                isConnected = false;
                isPlaying = false;
                updateUI();
                clearTimeout(reconnectTimer);
                reconnectTimer = setTimeout(connectWebSocket, 1500);
            };

            ws.onerror = function(err) {
                logAudioEvent('ws_error');
                isConnected = false;
                isPlaying = false;
                updateUI();
            };
        } catch (e) {
            logAudioEvent('ws_init_exception', { error: e.message });
            clearTimeout(reconnectTimer);
            reconnectTimer = setTimeout(connectWebSocket, 1500);
        }
    }

    function init() {
        logAudioEvent('audio_client_init');
        createUI();
        connectWebSocket();
        startPcmWatchdog();
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', init);
    } else {
        init();
    }
})();
