let STREAMS = [];
const HLS_BASE = '/hls';
const WEBRTC_BASE = '/webrtc';
const API_BASE = '';

const players = {};

// Initialize camera grid
async function init() {
    // Fetch camera list from server
    try {
        const res = await fetch(`${API_BASE}/api/streams`);
        const data = await res.json();
        STREAMS = (data.items || []).map(i => i.name);
    } catch {
        STREAMS = ['cam2', 'cam3']; // fallback
    }

    const grid = document.getElementById('camera-grid');
    STREAMS.forEach(name => {
        const card = document.createElement('div');
        card.className = 'cam-card';
        card.id = `card-${name}`;
        card.innerHTML = `
            <video id="video-${name}" muted autoplay playsinline></video>
            <div class="label">
                <span>${name.toUpperCase()}</span>
                <button onclick="switchTo('${name}')">Switch</button>
            </div>
        `;
        grid.appendChild(card);
    });

    // Start WebRTC players (HLS fallback)
    STREAMS.forEach(startPreview);

    // Poll status
    setInterval(pollStatus, 2000);
    pollStatus();

    // Poll overlay status
    setInterval(pollOverlayStatus, 3000);
    pollOverlayStatus();

    // Restore saved overlay URL
    const savedUrl = localStorage.getItem('overlay-url');
    if (savedUrl) document.getElementById('overlay-url').value = savedUrl;

    // Restore saved YouTube stream key
    const youtubeKeyInput = document.getElementById('youtube-key');
    const savedYouTubeKey = localStorage.getItem('youtube-key');
    if (savedYouTubeKey && youtubeKeyInput) {
        youtubeKeyInput.value = savedYouTubeKey;
    }
    if (youtubeKeyInput) {
        youtubeKeyInput.addEventListener('input', () => {
            localStorage.setItem('youtube-key', youtubeKeyInput.value.trim());
        });
    }

    // Update default max rows when format changes
    document.getElementById('overlay-format').addEventListener('change', function() {
        const rowsInput = document.getElementById('overlay-max-rows');
        switch (this.value) {
            case 'condensed': rowsInput.value = 20; break;
            case 'minimal':   rowsInput.value = 15; break;
            default:          rowsInput.value = 10; break;
        }
    });
}

function startPreview(name) {
    startWebRTC(name).catch(() => {
        console.warn(`WebRTC failed for ${name}, falling back to HLS (will retry WebRTC in 10s)`);
        startHLS(name);
        // Retry WebRTC periodically — upgrade from HLS when stream becomes available
        scheduleWebRTCRetry(name);
    });
}

function scheduleWebRTCRetry(name) {
    setTimeout(() => {
        const p = players[name];
        if (p && p.type === 'webrtc') return; // already upgraded
        startWebRTC(name).then(() => {
            // WebRTC succeeded — tear down HLS
            if (p && p.type === 'hls' && p.hls) {
                p.hls.destroy();
            }
            console.log(`Upgraded ${name} from HLS to WebRTC`);
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

    const res = await fetch(`${WEBRTC_BASE}/${name}/whep`, {
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

    players[name] = { pc, sessionURL, type: 'webrtc' };
    video.play().catch(() => {});
}

function cleanupWebRTC(name) {
    const p = players[name];
    if (!p) return;
    if (p.type === 'webrtc' && p.pc) {
        p.pc.close();
    }
    delete players[name];
}

function startHLS(name) {
    const video = document.getElementById(`video-${name}`);
    const url = `${HLS_BASE}/${name}/index.m3u8`;

    if (Hls.isSupported()) {
        const hls = new Hls({
            enableWorker: true,
            lowLatencyMode: false,
            liveSyncDurationCount: 2,
            liveMaxLatencyDurationCount: 4,
            maxBufferLength: 4,
            backBufferLength: 0,
        });
        hls.loadSource(url);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, () => video.play().catch(() => {}));
        hls.on(Hls.Events.ERROR, (_, data) => {
            if (data.fatal) {
                setTimeout(() => {
                    hls.loadSource(url);
                    hls.attachMedia(video);
                }, 3000);
            }
        });
        players[name] = { hls, type: 'hls' };
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
        video.src = url;
        video.play().catch(() => {});
    }
}

async function switchTo(stream) {
    try {
        const res = await fetch(`${API_BASE}/api/switch`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ stream }),
        });
        const data = await res.json();
        if (!res.ok) {
            alert(data.error || 'Switch failed');
        }
        pollStatus();
    } catch (err) {
        alert('Error: ' + err.message);
    }
}

let outputPlayer = null;
let outputPreviewPaused = false;
let outputPreviewStream = null;

async function goLive() {
    const key = document.getElementById('youtube-key').value.trim();
    const audioEnabled = document.getElementById('audio-enabled').checked;

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

    // Show unmute button
    const btn = document.getElementById('btn-unmute');
    if (btn) btn.style.display = 'block';

    const toggleBtn = document.getElementById('btn-toggle-preview');
    if (toggleBtn) toggleBtn.textContent = '⏸ Pause Preview';

    connectOutput(stream);
}

function unmuteOutput() {
    const video = document.getElementById('video-output');
    video.muted = false;
    outputUserUnmuted = true;
    video.play().catch(() => {});
    const btn = document.getElementById('btn-unmute');
    if (btn) btn.style.display = 'none';
}

function connectOutput(stream) {
    // Stream changed while we were waiting to retry — abort
    if (outputPreviewPaused) return;
    if (currentOutputStream !== stream) return;

    startOutputWebRTC(stream).catch(() => {
        console.warn('Output WebRTC failed, retrying in 3s');
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

    // Collect both tracks before attaching to avoid A/V desync from
    // video buffering while audio is still negotiating.
    const pendingTracks = [];
    let tracksExpected = 2;

    pc.ontrack = (event) => {
        console.log('[output] ontrack:', event.track.kind, event.track.readyState);
        pendingTracks.push(event.track);
        if (pendingTracks.length >= tracksExpected) {
            const ms = new MediaStream(pendingTracks);
            video.srcObject = ms;
            console.log('[output] attached both tracks, starting playback');
            video.muted = !outputUserUnmuted;
            video.play().catch(() => {});
            const unmuteBtn = document.getElementById('btn-unmute');
            if (unmuteBtn) unmuteBtn.style.display = video.muted ? 'block' : 'none';
        }
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

    const res = await fetch(`${WEBRTC_BASE}/${stream}/whep`, {
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

function startOutputHLS(stream) {
    const video = document.getElementById('video-output');
    const url = `${HLS_BASE}/${stream}/index.m3u8`;

    if (Hls.isSupported()) {
        const hls = new Hls({
            enableWorker: true,
            lowLatencyMode: false,
            liveSyncDurationCount: 2,
            liveMaxLatencyDurationCount: 4,
            maxBufferLength: 4,
            backBufferLength: 0,
        });
        hls.loadSource(url);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, () => {
            video.muted = false;
            video.play().catch(() => {});
        });
        hls.on(Hls.Events.ERROR, (_, data) => {
            if (data.fatal) {
                if (outputPreviewPaused) return;
                hls.destroy();
                outputPlayer = null;
                // Retry without resetting currentOutputStream (prevents poll race)
                setTimeout(() => connectOutput(stream), 3000);
            }
        });
        outputPlayer = { hls, type: 'hls' };
    }
}

function hideOutputPreview() {
    const section = document.getElementById('output-section');
    const video = document.getElementById('video-output');
    section.classList.add('hidden');
    if (outputPlayer) {
        if (outputPlayer.type === 'webrtc' && outputPlayer.pc) {
            outputPlayer.pc.close();
        } else if (outputPlayer.type === 'hls' && outputPlayer.hls) {
            outputPlayer.hls.destroy();
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

    const body = {};
    if (input.startsWith('http')) {
        body.url = input;
    } else {
        body.event_id = input;
    }
    body.format = format;
    body.max_rows = maxRows;

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

    if (data.active) {
        statusText.textContent = 'Active';
        statusText.className = 'overlay-active';
        competitors.textContent = `${data.competitors} competitors`;
        btnStart.disabled = true;
        btnStop.disabled = false;
    } else {
        statusText.textContent = 'Off';
        statusText.className = '';
        competitors.textContent = '';
        btnStart.disabled = false;
        btnStop.disabled = true;
    }
}
