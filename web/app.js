let STREAMS = [];
let ALL_CAMERAS = [];
const WEBRTC_BASE = '/webrtc';
const API_BASE = '';

// Camera streams use -opus paths for WebRTC (AAC→Opus transcode)
function whepPath(name) {
    if (/^cam\d+$/.test(name)) return name + '-opus';
    return name;
}

const players = {};

// Initialize camera grid
async function init() {
    // Fetch and display build version
    try {
        const vRes = await fetch(`${API_BASE}/api/version`);
        const vData = await vRes.json();
        const el = document.getElementById('build-version');
        if (el) el.textContent = vData.build || '';
    } catch {}

    // Fetch camera list from server
    try {
        const res = await fetch(`${API_BASE}/api/streams`);
        const data = await res.json();
        ALL_CAMERAS = (data.items || []).map(i => i.name);
        STREAMS = (data.items || []).filter(i => i.ready).map(i => i.name);
    } catch {
        ALL_CAMERAS = ['cam2', 'cam3'];
        STREAMS = ALL_CAMERAS;
    }

    const grid = document.getElementById('camera-grid');
    STREAMS.forEach(name => {
        const card = document.createElement('div');
        card.className = 'cam-card';
        card.id = `card-${name}`;
        const isUpscaled = name.endsWith('-4k');
        const label = isUpscaled ? `${name.replace('-4k','').toUpperCase()} <span class="ai-badge">AI SHARP</span>` : name.toUpperCase();
        card.innerHTML = `
            <video id="video-${name}" muted autoplay playsinline controls></video>
            <div class="label">
                <span>${label}</span>
                <button onclick="switchTo('${name}')">Switch</button>
            </div>
        `;
        grid.appendChild(card);
    });

    // Start WebRTC players
    const previewsEnabled = localStorage.getItem('cam-previews-enabled') !== 'false';
    document.getElementById('cam-previews-enabled').checked = previewsEnabled;
    if (previewsEnabled) {
        STREAMS.forEach(startPreview);
    } else {
        document.getElementById('camera-grid').style.display = 'none';
    }

    // Poll status
    setInterval(pollStatus, 2000);
    pollStatus();

    // Poll camera availability (show/hide cameras that come online/offline)
    setInterval(refreshCameraGrid, 5000);

    // Poll overlay status
    setInterval(pollOverlayStatus, 3000);
    pollOverlayStatus();

    // Poll ads
    setInterval(pollAds, 3000);
    pollAds();
    setInterval(pollAdPlayback, 2000);

    // Poll logo status
    pollLogoStatus();

    // Init stream quality config
    initStreamQuality();

    // Load server-side config, fall back to localStorage
    let serverCfg = {};
    try {
        const cfgRes = await fetch(`${API_BASE}/api/config`);
        if (cfgRes.ok) serverCfg = await cfgRes.json();
    } catch { /* server not reachable, use localStorage */ }

    // Overlay URL: server > localStorage
    const overlayUrl = serverCfg.overlay_url || localStorage.getItem('overlay-url') || '';
    if (overlayUrl) document.getElementById('overlay-url').value = overlayUrl;

    // Overlay title: localStorage
    const overlayTitle = localStorage.getItem('overlay-title') || '';
    if (overlayTitle) document.getElementById('overlay-title').value = overlayTitle;

    // Overlay format: server > default
    if (serverCfg.overlay_format) document.getElementById('overlay-format').value = serverCfg.overlay_format;

    // Overlay max rows: server > default
    if (serverCfg.overlay_max_rows) document.getElementById('overlay-max-rows').value = serverCfg.overlay_max_rows;

    // Overlay scale: server > localStorage > default
    const overlayScale = serverCfg.overlay_scale || localStorage.getItem('overlay-scale') || '';
    if (overlayScale) document.getElementById('overlay-scale').value = overlayScale;

    // Camera volume: server > default (30)
    if (serverCfg.camera_volume !== undefined && serverCfg.camera_volume !== null) {
        document.getElementById('camera-vol').value = serverCfg.camera_volume;
        const valSpan = document.getElementById('camera-vol-val');
        if (valSpan) valSpan.textContent = serverCfg.camera_volume + '%';
    }

    // Populate mic device selector
    populateMicDevices();

    // YouTube stream key: populate datalist from history
    const youtubeKeyInput = document.getElementById('youtube-key');
    populateYoutubeKeyHistory();

    // Audio enabled: server > default (checked)
    if (serverCfg.audio_enabled !== undefined && serverCfg.audio_enabled !== null) {
        document.getElementById('audio-enabled').checked = serverCfg.audio_enabled;
    }

    // Sync camera volume to server so it's ready for the next Go Live
    updateCommentaryVolume();

    // Update default max rows when format changes
    document.getElementById('overlay-format').addEventListener('change', function() {
        const rowsInput = document.getElementById('overlay-max-rows');
        switch (this.value) {
            case 'full':      rowsInput.value = 10; break;
            case 'condensed': rowsInput.value = 20; break;
            case 'minimal':   rowsInput.value = 15; break;
            default:          rowsInput.value = 20; break;
        }
    });
}

function startPreview(name) {
    startWebRTC(name).catch(() => {
        console.warn(`WebRTC failed for ${name}, retrying in 10s`);
        scheduleWebRTCRetry(name);
    });
}

function scheduleWebRTCRetry(name) {
    setTimeout(() => {
        const p = players[name];
        if (p && p.type === 'webrtc') return; // already connected
        startWebRTC(name).then(() => {
            console.log(`WebRTC connected for ${name}`);
        }).catch(() => {
            scheduleWebRTCRetry(name); // keep trying
        });
    }, 10000);
}

async function startWebRTC(name) {
    const video = document.getElementById(`video-${name}`);
    const pc = new RTCPeerConnection({ iceServers: [] });

    pc.addTransceiver('video', { direction: 'recvonly' });
    pc.addTransceiver('audio', { direction: 'recvonly' });

    pc.ontrack = (event) => {
        if (event.streams[0]) video.srcObject = event.streams[0];
        if (event.receiver && event.receiver.playoutDelayHint !== undefined) {
            event.receiver.playoutDelayHint = 0;
        }
        if (event.receiver && event.receiver.jitterBufferTarget !== undefined) {
            event.receiver.jitterBufferTarget = 0;
        }
    };

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    // Wait for ICE gathering (local candidates only, fast)
    await new Promise((resolve) => {
        if (pc.iceGatheringState === 'complete') return resolve();
        const check = () => {
            if (pc.iceGatheringState === 'complete') {
                pc.removeEventListener('icegatheringstatechange', check);
                resolve();
            }
        };
        pc.addEventListener('icegatheringstatechange', check);
        // Timeout fallback
        setTimeout(resolve, 500);
    });

    const res = await fetch(`${WEBRTC_BASE}/${whepPath(name)}/whep`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/sdp' },
        body: pc.localDescription.sdp,
    });
    if (!res.ok) throw new Error(`WHEP ${res.status}`);

    const answerSDP = await res.text();
    await pc.setRemoteDescription({ type: 'answer', sdp: answerSDP });

    // Store session URL for cleanup
    const sessionURL = res.headers.get('Location');

    // Reconnect on failure
    pc.onconnectionstatechange = () => {
        if (pc.connectionState === 'failed' || pc.connectionState === 'disconnected') {
            cleanupWebRTC(name);
            setTimeout(() => startPreview(name), 2000);
        }
    };

    // Detect stalled video (publisher reconnected but WebRTC session got no new frames)
    let lastBytes = 0;
    let stallCount = 0;
    const stallTimer = setInterval(async () => {
        if (!players[name] || players[name].pc !== pc) { clearInterval(stallTimer); return; }
        try {
            const stats = await pc.getStats();
            let currentBytes = 0;
            stats.forEach(s => { if (s.type === 'inbound-rtp' && s.kind === 'video') currentBytes = s.bytesReceived || 0; });
            if (currentBytes > 0 && currentBytes === lastBytes) {
                stallCount++;
                if (stallCount >= 3) { clearInterval(stallTimer); cleanupWebRTC(name); setTimeout(() => startPreview(name), 2000); }
            } else {
                stallCount = 0;
            }
            lastBytes = currentBytes;
        } catch { clearInterval(stallTimer); }
    }, 3000);

    players[name] = { pc, sessionURL, type: 'webrtc', stallTimer };
    video.play().catch(() => {});
}

function cleanupWebRTC(name) {
    const p = players[name];
    if (!p) return;
    if (p.stallTimer) clearInterval(p.stallTimer);
    if (p.type === 'webrtc' && p.pc) {
        p.pc.close();
    }
    delete players[name];
}

function toggleCamPreviews() {
    const enabled = document.getElementById('cam-previews-enabled').checked;
    localStorage.setItem('cam-previews-enabled', enabled);
    const grid = document.getElementById('camera-grid');
    if (enabled) {
        grid.style.display = '';
        STREAMS.forEach(name => {
            if (!players[name]) startPreview(name);
        });
    } else {
        grid.style.display = 'none';
        STREAMS.forEach(name => {
            cleanupPlayer(name);
            const video = document.getElementById(`video-${name}`);
            if (video) video.srcObject = null;
        });
    }
}

function cleanupPlayer(name) {
    const p = players[name];
    if (!p) return;
    if (p.stallTimer) clearInterval(p.stallTimer);
    if (p.type === 'webrtc' && p.pc) p.pc.close();
    delete players[name];
}

async function switchTo(stream) {
    const t0 = performance.now();
    console.log(`[switch] requesting switch to ${stream}`);

    // Capture pre-switch video frame count to detect when new frames arrive
    const outputVideo = document.getElementById('video-output');
    const preFrames = outputVideo ? outputVideo.getVideoPlaybackQuality?.()?.totalVideoFrames : null;

    try {
        const res = await fetch(`${API_BASE}/api/switch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ stream }),
        });
        const data = await res.json();
        const apiMs = (performance.now() - t0).toFixed(0);
        if (!res.ok) {
            console.warn(`[switch] API failed after ${apiMs}ms:`, data.error);
            alert(data.error || 'Switch failed');
        } else {
            console.log(`[switch] API responded in ${apiMs}ms`);
            // Monitor when new video frames actually arrive at the output preview
            if (outputVideo && preFrames !== null) {
                let checks = 0;
                const frameCheck = setInterval(() => {
                    const q = outputVideo.getVideoPlaybackQuality?.();
                    if (!q) { clearInterval(frameCheck); return; }
                    const newFrames = q.totalVideoFrames - preFrames;
                    const dropped = q.droppedVideoFrames;
                    checks++;
                    if (newFrames > 0) {
                        console.log(`[switch] first new frame after ${(performance.now() - t0).toFixed(0)}ms (${newFrames} frames, ${dropped} dropped)`);
                        clearInterval(frameCheck);
                    } else if (checks > 100) {
                        console.warn(`[switch] no new frames after ${(performance.now() - t0).toFixed(0)}ms, giving up`);
                        clearInterval(frameCheck);
                    }
                }, 50);
            }
        }
        pollStatus();
    } catch (err) {
        console.error(`[switch] fetch error after ${(performance.now() - t0).toFixed(0)}ms:`, err);
        alert('Error: ' + err.message);
    }
}

let outputPlayer = null;
let outputPreviewPaused = false;
let outputPreviewStream = null;

function populateYoutubeKeyHistory() {
    const datalist = document.getElementById('youtube-key-history');
    if (!datalist) return;
    // Migrate old single-key storage to history array
    const oldKey = localStorage.getItem('youtube-key');
    if (oldKey) {
        let keys = JSON.parse(localStorage.getItem('youtube-key-history') || '[]');
        if (!keys.includes(oldKey)) keys.push(oldKey);
        localStorage.setItem('youtube-key-history', JSON.stringify(keys));
        localStorage.removeItem('youtube-key');
    }
    datalist.innerHTML = '';
    const keys = JSON.parse(localStorage.getItem('youtube-key-history') || '[]');
    keys.forEach(k => {
        const opt = document.createElement('option');
        opt.value = k;
        datalist.appendChild(opt);
    });
}

function saveYoutubeKeyHistory(key) {
    if (!key) return;
    let keys = JSON.parse(localStorage.getItem('youtube-key-history') || '[]');
    keys = keys.filter(k => k !== key);
    keys.unshift(key); // most recent first
    if (keys.length > 20) keys = keys.slice(0, 20);
    localStorage.setItem('youtube-key-history', JSON.stringify(keys));
    populateYoutubeKeyHistory();
}

async function goLive() {
    const key = document.getElementById('youtube-key').value.trim();
    const audioEnabled = document.getElementById('audio-enabled').checked;
    saveYoutubeKeyHistory(key);

    // Sync camera volume to server before starting pipeline
    const cameraVol = parseInt(document.getElementById('camera-vol').value) / 100;
    await fetch(`${API_BASE}/api/commentary/update`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ camera_volume: cameraVol }),
    });

    const body = { stream: STREAMS[0] || 'cam1', audio: audioEnabled };
    if (key) {
        body.youtube_key = key;
        console.log(`YouTube RTMP destination: rtmp://a.rtmp.youtube.com/live2/${key}`);
    }
    // If no key, server uses local RTMP (rtmp://localhost:1935/live-output)

    try {
        const res = await fetch(`${API_BASE}/api/live/start`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
        const data = await res.json();
        if (!res.ok) {
            alert(data.error || 'Failed to go live');
        }
        pollStatus();
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

async function stopLive() {
    try {
        const res = await fetch(`${API_BASE}/api/live/stop`, { method: 'POST' });
        const data = await res.json();
        if (!res.ok) {
            alert(data.error || 'Failed to stop');
        }
        pollStatus();
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

async function pollStatus() {
    try {
        const res = await fetch(`${API_BASE}/api/status`);
        const status = await res.json();
        updateUI(status);
    } catch {
        // Server not reachable
    }
    // Also poll commentary slot state for cross-device visibility
    try {
        const res = await fetch(`${API_BASE}/api/commentary/status`);
        const data = await res.json();
        updateCommentaryUI(data);
    } catch { /* ignore */ }
}

// Update commentary slot UI based on server state (cross-device visibility)
function updateCommentaryUI(data) {
    if (!data.slots) return;
    for (const slot of data.slots) {
        const i = slot.index;
        const statusEl = document.getElementById(`comm-status-${i}`);
        const btn = document.getElementById(`btn-comm-${i}`);
        const kickBtn = document.getElementById(`btn-kick-${i}`);
        if (!statusEl || !btn) continue;

        // Skip if this is our own active slot (we manage our own state)
        if (commentaryState.slots[i].active) {
            if (kickBtn) kickBtn.classList.add('hidden');
            continue;
        }

        if (slot.active) {
            // Someone else is on this slot
            statusEl.textContent = 'In Use';
            statusEl.className = 'comm-status in-use';
            btn.textContent = 'In Use';
            btn.disabled = true;
            btn.style.background = '#666';
            if (kickBtn) kickBtn.classList.remove('hidden');
        } else {
            // Slot is free — only reset if we previously showed "In Use"
            if (btn.textContent === 'In Use') {
                statusEl.textContent = 'Disconnected';
                statusEl.className = 'comm-status';
                btn.textContent = 'Join';
                btn.disabled = false;
                btn.style.background = '';
            }
            if (kickBtn) kickBtn.classList.add('hidden');
        }
    }
}

async function kickCommentary(slot) {
    if (!confirm(`Kick Commentator ${slot + 1}?`)) return;
    try {
        await fetch(`${API_BASE}/api/commentary/kick`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ slot }),
        });
        const kickBtn = document.getElementById(`btn-kick-${slot}`);
        if (kickBtn) kickBtn.classList.add('hidden');
    } catch (err) {
        console.error('Kick failed:', err);
    }
}

function updateUI(status) {
    const badge = document.getElementById('live-badge');
    const statusText = document.getElementById('status-text');
    const activeStream = document.getElementById('active-stream');
    const btnLive = document.getElementById('btn-go-live');
    const btnStop = document.getElementById('btn-stop');

    if (status.live) {
        badge.classList.remove('hidden');
        statusText.textContent = 'LIVE';
        statusText.className = 'live';
        activeStream.textContent = `Active: ${status.active_stream}`;
        btnLive.disabled = true;
        btnStop.disabled = false;
        if (status.preview_ready !== false) {
            // Watch live-preview (has H264 video + Opus audio via rtspclientsink).
            showOutputPreview('live-preview');
        } else {
            hideOutputPreview();
        }
    } else {
        badge.classList.add('hidden');
        statusText.textContent = 'Idle';
        statusText.className = '';
        activeStream.textContent = '';
        btnLive.disabled = false;
        btnStop.disabled = true;
        hideOutputPreview();
    }

    // Highlight active card
    STREAMS.forEach(name => {
        const card = document.getElementById(`card-${name}`);
        card.classList.toggle('active', name === status.active_stream);
    });
}

document.addEventListener('DOMContentLoaded', init);

let currentOutputStream = null;

let outputUserUnmuted = false;

// Track when user unmutes the output preview via video controls
document.addEventListener('DOMContentLoaded', () => {
    const v = document.getElementById('video-output');
    if (v) v.addEventListener('volumechange', () => { outputUserUnmuted = !v.muted; });
});

function showOutputPreview(stream) {
    const section = document.getElementById('output-section');
    outputPreviewStream = stream;

    if (outputPreviewPaused) {
        section.classList.remove('hidden');
        return;
    }

    // Already showing/connecting/retrying this stream — no-op
    if (currentOutputStream === stream) {
        section.classList.remove('hidden');
        return;
    }

    hideOutputPreview();
    currentOutputStream = stream;
    section.classList.remove('hidden');

    const toggleBtn = document.getElementById('btn-toggle-preview');
    if (toggleBtn) toggleBtn.textContent = '⏸ Pause Preview';

    connectOutput(stream);
}

function connectOutput(stream) {
    // Stream changed while we were waiting to retry — abort
    if (outputPreviewPaused) return;
    if (currentOutputStream !== stream) return;

    startOutputWebRTC(stream).catch((err) => {
        console.warn(`Output WebRTC failed for ${stream}: ${err.message}, retrying in 3s`);
        if (currentOutputStream === stream) {
            setTimeout(() => connectOutput(stream), 3000);
        }
    });
}

async function startOutputWebRTC(stream) {
    const video = document.getElementById('video-output');
    const pc = new RTCPeerConnection({ iceServers: [] });

    pc.addTransceiver('video', { direction: 'recvonly' });
    pc.addTransceiver('audio', { direction: 'recvonly' });

    pc.ontrack = (event) => {
        console.log('[output] ontrack:', event.track.kind, event.track.readyState);
        const wasMuted = video.muted;
        if (event.streams[0]) {
            video.srcObject = event.streams[0];
        } else {
            if (!video.srcObject) {
                video.srcObject = new MediaStream();
            }
            video.srcObject.addTrack(event.track);
        }
        if (event.receiver && event.receiver.playoutDelayHint !== undefined) {
            event.receiver.playoutDelayHint = 0;
        }
        if (event.receiver && event.receiver.jitterBufferTarget !== undefined) {
            event.receiver.jitterBufferTarget = 0;
        }
        video.muted = wasMuted;
        video.play().catch(() => {});
    };

    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    console.log('[output] offer audio m-lines:', (pc.localDescription.sdp.match(/m=audio/g) || []).length);

    await new Promise((resolve) => {
        if (pc.iceGatheringState === 'complete') return resolve();
        const check = () => {
            if (pc.iceGatheringState === 'complete') {
                pc.removeEventListener('icegatheringstatechange', check);
                resolve();
            }
        };
        pc.addEventListener('icegatheringstatechange', check);
        setTimeout(resolve, 500);
    });

    const res = await fetch(`${WEBRTC_BASE}/${whepPath(stream)}/whep`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/sdp' },
        body: pc.localDescription.sdp,
    });
    if (!res.ok) throw new Error(`WHEP ${res.status}`);

    const answerSDP = await res.text();
    console.log('[output] answer audio m-lines:', (answerSDP.match(/m=audio/g) || []).length);
    console.log('[output] answer has opus:', answerSDP.includes('opus'));
    await pc.setRemoteDescription({ type: 'answer', sdp: answerSDP });

    pc.onconnectionstatechange = () => {
        if (pc.connectionState === 'failed' || pc.connectionState === 'disconnected') {
            if (outputPreviewPaused) return;
            if (currentOutputStream === stream) {
                // Cleanup player but keep currentOutputStream so poll doesn't re-trigger
                if (outputPlayer && outputPlayer.pc) outputPlayer.pc.close();
                outputPlayer = null;
                setTimeout(() => connectOutput(stream), 2000);
            }
        }
    };

    outputPlayer = { pc, type: 'webrtc' };
}

function hideOutputPreview() {
    const section = document.getElementById('output-section');
    const video = document.getElementById('video-output');
    section.classList.add('hidden');
    if (outputPlayer) {
        if (outputPlayer.type === 'webrtc' && outputPlayer.pc) {
            outputPlayer.pc.close();
        }
        outputPlayer = null;
    }
    video.srcObject = null;
    currentOutputStream = null;
}

function pauseOutputPreview() {
    outputPreviewPaused = true;
    const btn = document.getElementById('btn-toggle-preview');
    if (btn) btn.textContent = '▶ Resume Preview';
    hideOutputPreview();
}

function resumeOutputPreview() {
    outputPreviewPaused = false;
    const btn = document.getElementById('btn-toggle-preview');
    if (btn) btn.textContent = '⏸ Pause Preview';
    if (outputPreviewStream) {
        showOutputPreview(outputPreviewStream);
    }
}

function toggleOutputPreview() {
    if (outputPreviewPaused) {
        resumeOutputPreview();
    } else {
        pauseOutputPreview();
    }
}

function toggleOutputMute() {
    const video = document.getElementById('video-output');
    const btn = document.getElementById('btn-unmute-output');
    if (video) {
        video.muted = !video.muted;
        console.log('[output] toggleMute: muted=' + video.muted, 'srcObject=' + !!video.srcObject, 'audioTracks=' + (video.srcObject ? video.srcObject.getAudioTracks().length : 0));
        if (video.srcObject) {
            video.srcObject.getAudioTracks().forEach(t => {
                console.log('[output] audio track:', t.id, 'enabled=' + t.enabled, 'readyState=' + t.readyState, 'muted=' + t.muted);
                t.enabled = true;
            });
        }
        if (btn) btn.textContent = video.muted ? '🔇 Unmute' : '🔊 Mute';
    }
}

// --- Overlay Controls ---

async function startOverlay() {
    const input = document.getElementById('overlay-url').value.trim();
    if (!input) {
        alert('Enter a SpeedHive URL or Event ID');
        return;
    }
    localStorage.setItem('overlay-url', input);

    const format = document.getElementById('overlay-format').value;
    const maxRows = parseInt(document.getElementById('overlay-max-rows').value, 10) || 0;
    const scale = parseFloat(document.getElementById('overlay-scale').value) || 1;
    localStorage.setItem('overlay-scale', scale);

    const title = document.getElementById('overlay-title').value.trim();
    localStorage.setItem('overlay-title', title);

    const body = {};
    if (input.startsWith('http')) {
        body.url = input;
    } else {
        body.event_id = input;
    }
    body.format = format;
    body.max_rows = maxRows;
    body.scale = scale;
    if (title) body.title = title;

    try {
        const res = await fetch(`${API_BASE}/api/overlay/start`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(body),
        });
        const data = await res.json();
        if (!res.ok) {
            alert(data.error || 'Failed to start overlay');
        }
        pollOverlayStatus();
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

async function stopOverlay() {
    try {
        const res = await fetch(`${API_BASE}/api/overlay/stop`, { method: 'POST' });
        const data = await res.json();
        if (!res.ok) {
            alert(data.error || 'Failed to stop overlay');
        }
        pollOverlayStatus();
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

async function updateOverlay() {
    const format = document.getElementById('overlay-format').value;
    const maxRows = parseInt(document.getElementById('overlay-max-rows').value, 10) || 0;
    const scale = parseFloat(document.getElementById('overlay-scale').value) || 1;
    const title = document.getElementById('overlay-title').value.trim();
    try {
        const res = await fetch(`${API_BASE}/api/overlay/update`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ format, max_rows: maxRows, scale, title: title || undefined }),
        });
        const data = await res.json();
        if (!res.ok) {
            alert(data.error || 'Failed to update overlay');
        }
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

async function pollOverlayStatus() {
    try {
        const res = await fetch(`${API_BASE}/api/overlay/status`);
        const data = await res.json();
        updateOverlayUI(data);
    } catch {
        // Server not reachable
    }
}

function updateOverlayUI(data) {
    const statusText = document.getElementById('overlay-status-text');
    const competitors = document.getElementById('overlay-competitors');
    const btnStart = document.getElementById('btn-overlay-start');
    const btnStop = document.getElementById('btn-overlay-stop');
    const btnUpdate = document.getElementById('btn-overlay-update');
    const flagControls = document.getElementById('flag-controls');

    if (data.active) {
        statusText.textContent = 'Active';
        statusText.className = 'overlay-active';
        competitors.textContent = `${data.competitors} competitors`;
        btnStart.disabled = true;
        btnStop.disabled = false;
        if (btnUpdate) btnUpdate.disabled = false;
        if (flagControls) flagControls.classList.remove('hidden');
    } else {
        statusText.textContent = 'Off';
        statusText.className = '';
        competitors.textContent = '';
        btnStart.disabled = false;
        btnStop.disabled = true;
        if (btnUpdate) btnUpdate.disabled = true;
        if (flagControls) flagControls.classList.add('hidden');
    }
}

// --- Commentary ---

const commentaryState = {
    slots: [
        { pc: null, stream: null, sessionURL: null, active: false, audioCtx: null, gainNode: null },
        { pc: null, stream: null, sessionURL: null, active: false, audioCtx: null, gainNode: null },
    ],
};

// Warn user before navigating away if commentary audio is connected
window.addEventListener('beforeunload', (e) => {
    const hasActive = commentaryState.slots.some(s => s.active);
    if (hasActive) {
        e.preventDefault();
    }
});

// Enumerate audio input devices and populate the mic selector
async function populateMicDevices() {
    const select = document.getElementById('mic-device');
    if (!select) return;

    // Need a temporary getUserMedia call to get permission, then enumerate
    try {
        const tempStream = await navigator.mediaDevices.getUserMedia({ audio: true });
        tempStream.getTracks().forEach(t => t.stop());
    } catch {
        // Permission denied — leave dropdown with just "Default"
        return;
    }

    const devices = await navigator.mediaDevices.enumerateDevices();
    const audioInputs = devices.filter(d => d.kind === 'audioinput');

    // Preserve current selection
    const saved = localStorage.getItem('mic-device-id') || '';
    select.innerHTML = '<option value="">Default</option>';

    audioInputs.forEach(d => {
        const opt = document.createElement('option');
        opt.value = d.deviceId;
        opt.textContent = d.label || `Mic (${d.deviceId.slice(0, 8)}...)`;
        if (d.deviceId === saved) opt.selected = true;
        select.appendChild(opt);
    });

    // Listen for device changes (plug/unplug)
    navigator.mediaDevices.ondevicechange = () => populateMicDevices();
}

function saveMicDevice() {
    const select = document.getElementById('mic-device');
    localStorage.setItem('mic-device-id', select.value);

    // If any commentary slot is active on this device, rejoin with the new device
    for (let i = 0; i < commentaryState.slots.length; i++) {
        if (commentaryState.slots[i].active) {
            console.log(`Mic device changed, rejoining commentary slot ${i}`);
            leaveCommentary(i).then(() => joinCommentary(i));
        }
    }
}

async function toggleCommentary(slot) {
    if (commentaryState.slots[slot].active) {
        await leaveCommentary(slot);
    } else {
        await joinCommentary(slot);
    }
}

async function joinCommentary(slot) {
    const statusEl = document.getElementById(`comm-status-${slot}`);
    const btn = document.getElementById(`btn-comm-${slot}`);

    try {
        statusEl.textContent = 'Connecting...';
        statusEl.className = 'comm-status';

        // Capture mic audio with selected device
        const selectedDeviceId = document.getElementById('mic-device')?.value || '';
        const audioConstraints = {
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
        };
        if (selectedDeviceId) {
            audioConstraints.deviceId = { exact: selectedDeviceId };
        }
        const stream = await navigator.mediaDevices.getUserMedia({
            audio: audioConstraints,
            video: false,
        });

        // Route mic through GainNode for browser-side volume control
        // (avoids pipeline restart when adjusting commentary volume)
        const audioCtx = new AudioContext();
        const source = audioCtx.createMediaStreamSource(stream);
        const gainNode = audioCtx.createGain();
        gainNode.gain.value = parseInt(document.getElementById(`comm-vol-${slot}`).value) / 100;
        const destination = audioCtx.createMediaStreamDestination();
        source.connect(gainNode);
        gainNode.connect(destination);

        const pc = new RTCPeerConnection({ iceServers: [] });

        // Add the gain-controlled audio track for WebRTC publishing
        destination.stream.getAudioTracks().forEach(track => {
            pc.addTrack(track, stream);
        });

        const offer = await pc.createOffer();
        await pc.setLocalDescription(offer);

        // Wait for ICE gathering
        await new Promise((resolve) => {
            if (pc.iceGatheringState === 'complete') return resolve();
            const check = () => {
                if (pc.iceGatheringState === 'complete') {
                    pc.removeEventListener('icegatheringstatechange', check);
                    resolve();
                }
            };
            pc.addEventListener('icegatheringstatechange', check);
            setTimeout(resolve, 2000);
        });

        // WHIP publish to MediaMTX — publishes to the -whip input path.
        // The server runs a relay from commentary-N-whip → commentary-N,
        // keeping the pipeline's rtspsrc connected without publisher changes.
        const whipPath = `commentary-${slot + 1}-whip`;
        const res = await fetch(`${WEBRTC_BASE}/${whipPath}/whip`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/sdp' },
            body: pc.localDescription.sdp,
        });

        if (!res.ok) {
            throw new Error(`WHIP publish failed: ${res.status}`);
        }

        const answerSDP = await res.text();
        await pc.setRemoteDescription({ type: 'answer', sdp: answerSDP });

        const sessionURL = res.headers.get('Location');

        commentaryState.slots[slot] = { pc, stream, sessionURL, active: true, audioCtx, gainNode };

        statusEl.textContent = 'Connected';
        statusEl.className = 'comm-status connected';
        btn.textContent = 'Leave';
        btn.style.background = '#f44336';

        // Notify server AFTER WHIP publish — this marks the slot active
        // so the silence publisher won't auto-restart after being overridden.
        await fetch(`${API_BASE}/api/commentary/slot`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ slot: slot, active: true }),
        });

        // Reconnect on failure — only on 'failed' (terminal).
        // 'disconnected' is often temporary (network hiccup) and can recover.
        let disconnectTimer = null;
        pc.onconnectionstatechange = () => {
            const state = pc.connectionState;
            console.log(`Commentary slot ${slot} connection: ${state}`);
            if (state === 'failed') {
                clearTimeout(disconnectTimer);
                console.warn(`Commentary slot ${slot} failed, cleaning up`);
                leaveCommentary(slot);
            } else if (state === 'disconnected') {
                // Give it 5s to recover before tearing down
                disconnectTimer = setTimeout(() => {
                    if (pc.connectionState === 'disconnected' || pc.connectionState === 'failed') {
                        console.warn(`Commentary slot ${slot} didn't recover, cleaning up`);
                        leaveCommentary(slot);
                    }
                }, 5000);
            } else if (state === 'connected') {
                clearTimeout(disconnectTimer);
            }
        };

    } catch (err) {
        console.error(`Commentary join failed for slot ${slot}:`, err);
        statusEl.textContent = 'Failed: ' + err.message;
        statusEl.className = 'comm-status';
        btn.textContent = 'Join';
        btn.style.background = '';
    }
}

async function leaveCommentary(slot) {
    const state = commentaryState.slots[slot];
    const statusEl = document.getElementById(`comm-status-${slot}`);
    const btn = document.getElementById(`btn-comm-${slot}`);

    // Close audio context
    if (state.audioCtx) {
        state.audioCtx.close();
    }

    // Stop mic
    if (state.stream) {
        state.stream.getTracks().forEach(t => t.stop());
    }

    // Close peer connection
    if (state.pc) {
        state.pc.close();
    }

    // Delete WHIP session if we have one
    if (state.sessionURL) {
        try {
            await fetch(state.sessionURL, { method: 'DELETE' });
        } catch { /* ignore */ }
    }

    commentaryState.slots[slot] = { pc: null, stream: null, sessionURL: null, active: false, audioCtx: null, gainNode: null };

    statusEl.textContent = 'Disconnected';
    statusEl.className = 'comm-status';
    btn.textContent = 'Join';
    btn.style.background = '';

    // Notify server (triggers silence publisher restart for this slot)
    await fetch(`${API_BASE}/api/commentary/slot`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ slot: slot, active: false }),
    });
}

let commentaryVolumeTimeout = null;
function updateCommentaryVolume() {
    // Per-commentator volume: update GainNode directly (no server call, no pipeline restart)
    for (let i = 0; i < 2; i++) {
        const slider = document.getElementById(`comm-vol-${i}`);
        const vol = parseInt(slider.value) / 100;
        const valSpan = document.getElementById(`comm-vol-${i}-val`);
        if (valSpan) valSpan.textContent = slider.value + '%';
        const state = commentaryState.slots[i];
        if (state.gainNode) {
            state.gainNode.gain.value = vol;
        }
    }

    // Camera volume: update label and debounce send to server
    const camSlider = document.getElementById('camera-vol');
    const camValSpan = document.getElementById('camera-vol-val');
    if (camValSpan) camValSpan.textContent = camSlider.value + '%';

    // Camera volume: debounce and send to server (may trigger pipeline restart)
    clearTimeout(commentaryVolumeTimeout);
    commentaryVolumeTimeout = setTimeout(async () => {
        const cameraVol = parseInt(document.getElementById('camera-vol').value) / 100;
        await fetch(`${API_BASE}/api/commentary/update`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ camera_volume: cameraVol }),
        });
    }, 300);
}

async function setFlag(flagStatus) {
    try {
        const res = await fetch(`${API_BASE}/api/overlay/flag`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ flag_status: flagStatus }),
        });
        if (res.ok) {
            const label = document.getElementById('flag-status-text');
            if (label) label.textContent = flagStatus ? `Active: ${flagStatus}` : '';
        }
    } catch (err) {
        console.error('Set flag failed:', err);
    }
}

// --- Logos ---

async function uploadLogo(position) {
    const key = position === 'top-right' ? 'top-right' : 'bot-right';
    const input = document.getElementById(`logo-${key}-file`);
    if (!input.files.length) return;
    const file = input.files[0];

    const form = new FormData();
    form.append('file', file);
    form.append('position', position);

    try {
        const res = await fetch(`${API_BASE}/api/logo/upload`, { method: 'POST', body: form });
        const data = await res.json();
        if (res.ok) {
            pollLogoStatus();
        } else {
            alert(data.error || 'Upload failed');
        }
    } catch (err) {
        alert('Upload failed: ' + err.message);
    }
    input.value = '';
}

async function removeLogo(position) {
    try {
        const res = await fetch(`${API_BASE}/api/logo/${position}`, { method: 'DELETE' });
        if (res.ok) {
            pollLogoStatus();
        }
    } catch (err) {
        alert('Remove failed: ' + err.message);
    }
}

let logoSettingsTimeout = null;
function updateLogoSettings(position) {
    const key = position === 'top-right' ? 'top-right' : 'bot-right';
    const opacitySlider = document.getElementById(`logo-${key}-opacity`);
    const opacityVal = document.getElementById(`logo-${key}-opacity-val`);
    const offsetInput = document.getElementById(`logo-${key}-offset`);

    if (opacityVal) opacityVal.textContent = opacitySlider.value + '%';

    clearTimeout(logoSettingsTimeout);
    logoSettingsTimeout = setTimeout(async () => {
        const opacity = parseInt(opacitySlider.value) / 100;
        const offset = parseInt(offsetInput.value) || 20;
        try {
            await fetch(`${API_BASE}/api/logo/settings`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ position, opacity, offset }),
            });
        } catch (err) {
            console.error('Logo settings update failed:', err);
        }
    }, 300);
}

async function pollLogoStatus() {
    try {
        const res = await fetch(`${API_BASE}/api/logo/status`);
        const data = await res.json();
        updateLogoUI('top-right', data.top_right);
        updateLogoUI('bottom-right', data.bottom_right);
    } catch {}
}

function updateLogoUI(position, info) {
    const key = position === 'top-right' ? 'top-right' : 'bot-right';
    const img = document.getElementById(`logo-${key}-img`);
    const placeholder = document.querySelector(`#logo-${key}-preview .logo-placeholder`);
    const removeBtn = document.getElementById(`logo-${key}-remove`);
    const opacitySlider = document.getElementById(`logo-${key}-opacity`);
    const opacityVal = document.getElementById(`logo-${key}-opacity-val`);
    const offsetInput = document.getElementById(`logo-${key}-offset`);

    if (info.has_logo) {
        if (img) {
            img.src = `${API_BASE}/api/logo/preview/${position}?t=${Date.now()}`;
            img.style.display = 'block';
        }
        if (placeholder) placeholder.style.display = 'none';
        if (removeBtn) removeBtn.style.display = '';
    } else {
        if (img) img.style.display = 'none';
        if (placeholder) placeholder.style.display = '';
        if (removeBtn) removeBtn.style.display = 'none';
    }

    if (opacitySlider) {
        opacitySlider.value = Math.round(info.opacity * 100);
        if (opacityVal) opacityVal.textContent = opacitySlider.value + '%';
    }
    if (offsetInput) offsetInput.value = info.offset;
}

// --- Ads ---

async function uploadAd() {
    const input = document.getElementById('ad-file');
    if (!input.files.length) return;
    const file = input.files[0];
    const status = document.getElementById('ad-upload-status');
    status.textContent = `Uploading ${file.name}...`;

    const form = new FormData();
    form.append('file', file);

    try {
        const res = await fetch(`${API_BASE}/api/ads/upload`, { method: 'POST', body: form });
        const data = await res.json();
        if (res.ok) {
            status.textContent = `Uploaded! Transcoding...`;
            pollAds();
        } else {
            status.textContent = `Error: ${data.error}`;
        }
    } catch (err) {
        status.textContent = `Upload failed: ${err.message}`;
    }
    input.value = '';
}

async function pollAds() {
    try {
        const res = await fetch(`${API_BASE}/api/ads`);
        const ads = await res.json();
        renderAdsTable(ads || []);
    } catch {}
}

function renderAdsTable(ads) {
    const tbody = document.getElementById('ads-tbody');
    if (!tbody) return;

    // Preserve checked state across re-renders
    const checkedIds = new Set([...document.querySelectorAll('.ad-check:checked')].map(c => c.dataset.id));

    tbody.innerHTML = '';
    if (!ads.length) {
        tbody.innerHTML = '<tr class="ads-empty-row"><td colspan="5" style="text-align:center;color:#555;padding:20px">No ads uploaded</td></tr>';
        updateAdPlayButton();
        return;
    }
    for (const ad of ads) {
        const tr = document.createElement('tr');
        const dur = ad.duration > 0 ? `${Math.round(ad.duration)}s` : '-';
        const statusClass = `status-${ad.status}`;
        const isReady = ad.status === 'ready';
        const wasChecked = checkedIds.has(ad.id) && isReady;
        tr.innerHTML = `
            <td><input type="checkbox" class="ad-check" data-id="${ad.id}" ${wasChecked ? 'checked' : ''} ${isReady ? '' : 'disabled'}></td>
            <td>${escapeHtml(ad.name)}</td>
            <td>${dur}</td>
            <td><span class="${statusClass}">${ad.status}</span></td>
            <td class="ad-actions">
                ${isReady ? `<button onclick="previewAd('${ad.id}')">▶ Preview</button>` : ''}
                <button class="del-btn" onclick="deleteAd('${ad.id}')">✕</button>
            </td>
        `;
        tbody.appendChild(tr);
    }

    // Update select-all state
    const allChecks = tbody.querySelectorAll('.ad-check:not(:disabled)');
    const selectAll = document.getElementById('ads-select-all');
    if (selectAll) selectAll.checked = allChecks.length > 0 && [...allChecks].every(c => c.checked);

    // Enable play button if any checked
    updateAdPlayButton();

    // Clear upload status if all done
    const status = document.getElementById('ad-upload-status');
    if (status && ads.every(a => a.status === 'ready' || a.status === 'error')) {
        if (status.textContent.includes('Transcoding')) status.textContent = '';
    }
}

function escapeHtml(s) {
    const d = document.createElement('div');
    d.textContent = s;
    return d.innerHTML;
}

function toggleAllAds(checked) {
    document.querySelectorAll('.ad-check:not(:disabled)').forEach(c => c.checked = checked);
    updateAdPlayButton();
}

function updateAdPlayButton() {
    const btn = document.getElementById('btn-ads-play');
    if (btn) {
        const any = document.querySelectorAll('.ad-check:checked').length > 0;
        btn.disabled = !any;
    }
}

// Listen for checkbox changes on ads table
document.addEventListener('change', (e) => {
    if (e.target.classList.contains('ad-check')) updateAdPlayButton();
});

function previewAd(id) {
    const container = document.getElementById('ad-preview-container');
    const video = document.getElementById('ad-preview-video');
    if (!container || !video) return;
    video.src = `${API_BASE}/api/ads/preview/${id}`;
    container.classList.remove('ad-preview-empty');
    video.play();
}

async function deleteAd(id) {
    if (!confirm('Delete this ad?')) return;
    try {
        await fetch(`${API_BASE}/api/ads/${id}`, { method: 'DELETE' });
        pollAds();
    } catch (err) {
        alert('Delete failed: ' + err.message);
    }
}

async function playSelectedAds() {
    const checks = document.querySelectorAll('.ad-check:checked');
    const ids = [...checks].map(c => c.dataset.id);
    if (!ids.length) return;

    try {
        const res = await fetch(`${API_BASE}/api/ads/play`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ ids }),
        });
        const data = await res.json();
        if (!res.ok) {
            alert(data.error || 'Failed to play ads');
        }
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

async function stopAds() {
    try {
        await fetch(`${API_BASE}/api/ads/stop`, { method: 'POST' });
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

let adWasPlaying = false;

async function pollAdPlayback() {
    try {
        const res = await fetch(`${API_BASE}/api/ads/playback`);
        const data = await res.json();
        const bar = document.getElementById('ad-playback-bar');
        const text = document.getElementById('ad-playback-text');
        const stopBtn = document.getElementById('btn-ads-stop');
        if (data.playing) {
            bar.classList.remove('hidden');
            text.textContent = `Playing ad ${data.current_idx}/${data.total}: ${data.current_ad}`;
            if (stopBtn) stopBtn.disabled = false;
            adWasPlaying = true;
        } else {
            bar.classList.add('hidden');
            text.textContent = '';
            if (stopBtn) stopBtn.disabled = true;
            adWasPlaying = false;
        }
    } catch {}
}

// === Camera Availability Refresh ===

async function refreshCameraGrid() {
    try {
        const res = await fetch(`${API_BASE}/api/streams`);
        const data = await res.json();
        const nowReady = (data.items || []).filter(i => i.ready).map(i => i.name);
        const grid = document.getElementById('camera-grid');
        const previewsEnabled = localStorage.getItem('cam-previews-enabled') !== 'false';

        // Add newly online cameras
        for (const name of nowReady) {
            if (!STREAMS.includes(name) && !document.getElementById(`card-${name}`)) {
                const card = document.createElement('div');
                card.className = 'cam-card';
                card.id = `card-${name}`;
                const isUpscaled = name.endsWith('-4k');
                const label = isUpscaled ? `${name.replace('-4k','').toUpperCase()} <span class="ai-badge">AI SHARP</span>` : name.toUpperCase();
                card.innerHTML = `
                    <video id="video-${name}" muted autoplay playsinline></video>
                    <div class="label">
                        <span>${label}</span>
                        <button onclick="switchTo('${name}')">Switch</button>
                    </div>
                `;
                grid.appendChild(card);
                STREAMS.push(name);
                if (previewsEnabled) startPreview(name);
            }
        }

        // Hide offline cameras (don't remove — just hide)
        for (const name of STREAMS) {
            const card = document.getElementById(`card-${name}`);
            if (card) {
                card.style.display = nowReady.includes(name) ? '' : 'none';
            }
        }
    } catch {}
}

// === Camera Stream Quality Config ===

async function initStreamQuality() {
    const select = document.getElementById('sq-camera');
    if (!select) return;
    select.innerHTML = '';
    // Add 'All Cameras' option
    const allOpt = document.createElement('option');
    allOpt.value = 'all';
    allOpt.textContent = 'ALL CAMERAS';
    select.appendChild(allOpt);
    for (const name of ALL_CAMERAS) {
        if (name.endsWith('-4k')) continue; // skip upscaled streams
        const opt = document.createElement('option');
        opt.value = name;
        opt.textContent = name.toUpperCase();
        select.appendChild(opt);
    }
    if (select.options.length > 0) {
        loadCameraConfig();
    }
}

async function loadCameraConfig() {
    const camera = document.getElementById('sq-camera').value;
    const status = document.getElementById('sq-status');
    if (!camera) return;
    if (camera === 'all') {
        status.textContent = 'Set values and apply to all cameras';
        status.className = 'sq-status';
        return;
    }
    status.textContent = 'Loading...';
    status.className = 'sq-status';
    try {
        const res = await fetch(`${API_BASE}/api/camera/stream-config?camera=${camera}`);
        if (!res.ok) {
            const err = await res.json();
            if (err.error === 'tailscale_auth_required') {
                status.textContent = 'Auth required';
                status.className = 'sq-status sq-error';
                if (err.auth_url && confirm('Tailscale SSH session expired. Open auth URL?')) {
                    window.open(err.auth_url, '_blank');
                }
                return;
            }
            status.textContent = err.error || 'Error';
            status.className = 'sq-status sq-error';
            return;
        }
        const data = await res.json();
        const cfg = data.config;

        // Populate fields
        const resSelect = document.getElementById('sq-resolution');
        const resVal = `${cfg.WIDTH || '2028'}x${cfg.HEIGHT || '1080'}`;
        // Set value or add custom option
        if ([...resSelect.options].some(o => o.value === resVal)) {
            resSelect.value = resVal;
        } else {
            const opt = document.createElement('option');
            opt.value = resVal;
            opt.textContent = `${cfg.WIDTH}×${cfg.HEIGHT} (custom)`;
            resSelect.appendChild(opt);
            resSelect.value = resVal;
        }

        document.getElementById('sq-fps').value = cfg.FPS || '30';
        document.getElementById('sq-bitrate').value = cfg.BITRATE || '12000';
        document.getElementById('sq-preset').value = cfg.SPEED_PRESET || 'superfast';

        status.textContent = 'Loaded';
        status.className = 'sq-status sq-ok';
        setTimeout(() => { status.textContent = ''; }, 2000);
    } catch (e) {
        status.textContent = 'Offline';
        status.className = 'sq-status sq-error';
    }
}

async function applyCameraConfig() {
    const camera = document.getElementById('sq-camera').value;
    const status = document.getElementById('sq-status');
    if (!camera) return;

    const [width, height] = document.getElementById('sq-resolution').value.split('x');
    const cfg = {
        WIDTH: width,
        HEIGHT: height,
        FPS: document.getElementById('sq-fps').value,
        BITRATE: document.getElementById('sq-bitrate').value,
        SPEED_PRESET: document.getElementById('sq-preset').value,
        PROTOCOL: 'rtmp',
        MEDIAMTX_HOST: '100.23.149.218',
    };

    // Build list of cameras to apply to
    const targets = camera === 'all'
        ? ALL_CAMERAS.filter(n => !n.endsWith('-4k'))
        : [camera];

    status.textContent = `Applying to ${targets.length} camera(s)...`;
    status.className = 'sq-status';

    const results = [];
    for (const cam of targets) {
        try {
            const res = await fetch(`${API_BASE}/api/camera/stream-config`, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ camera: cam, config: cfg }),
            });
            if (!res.ok) {
                const err = await res.json();
                if (err.error === 'tailscale_auth_required') {
                    if (err.auth_url && confirm(`${cam}: Tailscale SSH expired. Open auth URL?`)) {
                        window.open(err.auth_url, '_blank');
                    }
                    results.push(`${cam}: auth required`);
                    continue;
                }
                results.push(`${cam}: ${err.error || 'failed'}`);
            } else {
                results.push(`${cam}: ok`);
            }
        } catch (e) {
            results.push(`${cam}: ${e.message}`);
        }
    }

    const allOk = results.every(r => r.endsWith(': ok'));
    if (allOk) {
        status.textContent = `Applied ✓ (${targets.length} camera(s) restarting)`;
        status.className = 'sq-status sq-ok';
    } else {
        status.textContent = results.join(', ');
        status.className = 'sq-status sq-error';
    }
    setTimeout(() => { status.textContent = ''; }, 5000);
}
