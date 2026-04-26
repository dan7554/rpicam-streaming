const STREAMS = ['cam1', 'cam2', 'cam3'];
const HLS_BASE = '/hls';
const API_BASE = '';

const players = {};

// Initialize camera grid
function init() {
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

    // Start HLS players
    STREAMS.forEach(startHLS);

    // Poll status
    setInterval(pollStatus, 2000);
    pollStatus();
}

function startHLS(name) {
    const video = document.getElementById(`video-${name}`);
    const url = `${HLS_BASE}/${name}/index.m3u8`;

    if (Hls.isSupported()) {
        const hls = new Hls({
            enableWorker: true,
            lowLatencyMode: true,
            liveSyncDurationCount: 1,
        });
        hls.loadSource(url);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, () => video.play().catch(() => {}));
        hls.on(Hls.Events.ERROR, (_, data) => {
            if (data.fatal) {
                // Retry after 3 seconds
                setTimeout(() => {
                    hls.loadSource(url);
                    hls.attachMedia(video);
                }, 3000);
            }
        });
        players[name] = hls;
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
        // Safari native HLS
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

async function goLive() {
    const key = document.getElementById('youtube-key').value.trim();

    const body = { stream: 'cam1' };
    if (key) {
        body.youtube_key = key;
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
        showOutputPreview(status.active_stream);
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

function showOutputPreview(stream) {
    const section = document.getElementById('output-section');
    const video = document.getElementById('video-output');
    const url = `${HLS_BASE}/${stream}/index.m3u8`;

    // If already showing the same stream, nothing to do
    if (outputPlayer && currentOutputStream === stream) {
        section.classList.remove('hidden');
        return;
    }

    // Clean up previous player (stream changed or first time)
    if (outputPlayer) {
        outputPlayer.destroy();
        outputPlayer = null;
    }
    currentOutputStream = stream;
    section.classList.remove('hidden');

    if (Hls.isSupported()) {
        outputPlayer = new Hls({
            enableWorker: true,
            liveSyncDurationCount: 3,
            liveMaxLatencyDurationCount: 10,
            maxBufferLength: 30,
        });
        outputPlayer.loadSource(url);
        outputPlayer.attachMedia(video);
        outputPlayer.on(Hls.Events.MANIFEST_PARSED, () => video.play().catch(() => {}));
        outputPlayer.on(Hls.Events.ERROR, (_, data) => {
            if (data.fatal) {
                outputPlayer.destroy();
                outputPlayer = null;
                currentOutputStream = null;
                setTimeout(() => showOutputPreview(stream), 3000);
            }
        });
    }
}

function hideOutputPreview() {
    const section = document.getElementById('output-section');
    section.classList.add('hidden');
    if (outputPlayer) {
        outputPlayer.destroy();
        outputPlayer = null;
    }
    currentOutputStream = null;
}
