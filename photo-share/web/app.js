// State
let currentUser = null;
let currentFolder = null;
let currentPhotos = [];
let lightboxIndex = -1;
let pendingFiles = [];
let viewingFavorites = false;

// Init
document.addEventListener('DOMContentLoaded', async () => {
    await loadUser();
    await loadVenmo();

    // Handle browser back/forward
    window.addEventListener('popstate', (e) => {
        if (e.state && e.state.favorites) {
            loadFavorites(false);
        } else if (e.state && e.state.folder) {
            loadFolder(e.state.folder, false);
        } else {
            loadHome(false);
        }
    });

    // Check URL hash for initial route
    const hash = window.location.hash.slice(1);
    if (hash === 'favorites') {
        loadFavorites(false);
    } else if (hash) {
        loadFolder(hash, false);
    } else {
        loadHome(false);
    }

    // Keyboard navigation for lightbox
    document.addEventListener('keydown', (e) => {
        if (document.getElementById('lightbox').classList.contains('hidden')) return;
        if (e.key === 'Escape') closeLightbox();
        if (e.key === 'ArrowLeft') prevPhoto(e);
        if (e.key === 'ArrowRight') nextPhoto(e);
    });

    // Drop zone events
    const dropZone = document.getElementById('drop-zone');
    dropZone.addEventListener('dragover', (e) => { e.preventDefault(); dropZone.classList.add('dragover'); });
    dropZone.addEventListener('dragleave', () => dropZone.classList.remove('dragover'));
    dropZone.addEventListener('drop', (e) => {
        e.preventDefault();
        dropZone.classList.remove('dragover');
        handleFiles(e.dataTransfer.files);
    });
});

// API helpers
async function api(path, opts = {}) {
    const resp = await fetch(path, opts);
    if (!resp.ok) {
        const err = await resp.json().catch(() => ({ error: resp.statusText }));
        throw new Error(err.error || 'request failed');
    }
    return resp.json();
}

// Auth
async function loadUser() {
    try {
        const data = await api('/api/me');
        if (data.logged_in) {
            currentUser = data;
            renderUserArea();
        } else {
            currentUser = null;
            renderUserArea();
        }
    } catch {
        currentUser = null;
        renderUserArea();
    }
}

function renderUserArea() {
    const area = document.getElementById('user-area');
    if (!currentUser) {
        area.innerHTML = `<a href="/auth/login" class="btn-google">
            <svg width="18" height="18" viewBox="0 0 18 18"><path fill="#4285F4" d="M16.51 8H8.98v3h4.3c-.18 1-.74 1.84-1.6 2.4v2h2.6c1.5-1.4 2.4-3.4 2.4-5.7 0-.5-.04-.9-.13-1.3z"/><path fill="#34A853" d="M8.98 17c2.16 0 3.97-.72 5.3-1.94l-2.6-2c-.72.48-1.63.76-2.7.76-2.07 0-3.83-1.4-4.46-3.28H1.85v2.06C3.18 15.35 5.85 17 8.98 17z"/><path fill="#FBBC05" d="M4.52 10.54c-.16-.48-.25-1-.25-1.54s.09-1.06.25-1.54V5.4H1.85C1.3 6.48 1 7.7 1 9s.31 2.52.85 3.6l2.67-2.06z"/><path fill="#EA4335" d="M8.98 4.18c1.17 0 2.22.4 3.05 1.2l2.28-2.28C12.94 1.72 11.14 1 8.98 1 5.85 1 3.18 2.65 1.85 5.4l2.67 2.06c.63-1.88 2.4-3.28 4.46-3.28z"/></svg>
            Sign in with Google
        </a>`;
    } else {
        area.innerHTML = `
            <a href="#favorites" onclick="event.preventDefault(); loadFavorites(true);" class="btn-favorites" title="My Favorites">${heartSVG(16)}<span class="fav-label">Favorites</span></a>
            ${currentUser.avatar ? `<img class="user-avatar" src="${currentUser.avatar}" alt="">` : ''}
            <span class="user-name">${currentUser.name}</span>
            <a href="/auth/logout" class="btn btn-secondary btn-small">Logout</a>
        `;
    }
}

// Navigation
function navigateTo(folderSlug) {
    if (folderSlug) {
        loadFolder(folderSlug, true);
    } else {
        loadHome(true);
    }
}

function loadHome(pushState = true) {
    currentFolder = null;
    viewingFavorites = false;
    if (pushState) history.pushState({}, '', '#');
    document.getElementById('nav-breadcrumb').innerHTML = '';
    loadFolders();
}

async function loadFolder(slug, pushState = true) {
    try {
        const folder = await api(`/api/folders/${slug}`);
        currentFolder = folder;
        if (pushState) history.pushState({ folder: slug }, '', `#${slug}`);

        // Build breadcrumbs
        let breadcrumb = `<a href="#" onclick="navigateTo(null); return false;">Home</a>`;
        if (folder.parent) {
            breadcrumb += `<span class="sep">›</span>
                <a href="#${folder.parent.slug}" onclick="navigateTo('${folder.parent.slug}'); return false;">${escHtml(folder.parent.name)}</a>`;
        }
        breadcrumb += `<span class="sep">›</span><span>${escHtml(folder.Name)}</span>`;
        document.getElementById('nav-breadcrumb').innerHTML = breadcrumb;

        // Load subfolders if top-level folder
        let subfolders = [];
        if (!folder.ParentID) {
            subfolders = await api(`/api/folders?parent_id=${folder.ID}`);
        }

        await loadPhotos(folder.ID, subfolders);
    } catch (err) {
        console.error('load folder error:', err);
        loadHome(true);
    }
}

// Folders
async function loadFolders() {
    const content = document.getElementById('content');
    try {
        const folders = await api('/api/folders');
        let html = '<div class="section-header"><h2>Galleries</h2>';
        if (currentUser?.is_admin) {
            html += `<div class="admin-actions">
                <button class="btn btn-primary" onclick="promptCreateFolder()">+ New Gallery</button>
            </div>`;
        }
        html += '</div>';

        if (folders.length === 0) {
            html += `<div class="empty-state">
                <div class="icon">📁</div>
                <p>No galleries yet${currentUser?.is_admin ? ' — create one to get started!' : '.'}</p>
            </div>`;
        } else {
            html += '<div class="folder-grid">';
            for (const f of folders) {
                const coverHtml = f.cover_url
                    ? `<img src="${f.cover_url}" alt="${f.Name}" loading="lazy">`
                    : '📁';
                html += `<div class="folder-card" onclick="navigateTo('${f.Slug}')">
                    <div class="folder-cover">${coverHtml}</div>
                    <div class="folder-info">
                        <div class="folder-name">${escHtml(f.Name)}</div>
                        <div class="folder-count">${f.PhotoCount} photo${f.PhotoCount !== 1 ? 's' : ''}</div>
                    </div>
                </div>`;
            }
            html += '</div>';
        }
        content.innerHTML = html;
    } catch (err) {
        content.innerHTML = `<div class="empty-state"><p>Error loading galleries</p></div>`;
    }
}

// Photos
async function loadPhotos(folderID, subfolders = []) {
    const content = document.getElementById('content');
    try {
        const photos = await api(`/api/folders/${folderID}/photos`);
        currentPhotos = photos;

        let html = `<div class="section-header"><h2>${escHtml(currentFolder.Name)}</h2>`;
        if (currentUser?.is_admin) {
            html += `<div class="admin-actions">
                <button class="btn btn-primary" onclick="openUploadModal()">+ Upload Photos</button>`;
            if (!currentFolder.ParentID) {
                html += `<button class="btn btn-secondary" onclick="promptCreateSubfolder(${currentFolder.ID})">+ Subfolder</button>`;
            }
            html += `<button class="btn btn-secondary" onclick="promptRenameFolder(${currentFolder.ID}, '${escAttr(currentFolder.Name)}')">Rename</button>
                <button class="btn btn-danger btn-small" onclick="promptDeleteFolder(${currentFolder.ID})">Delete Gallery</button>
            </div>`;
        }
        html += '</div>';

        // Render subfolders if any
        if (subfolders.length > 0) {
            html += '<div class="folder-grid subfolder-grid">';
            for (const f of subfolders) {
                const coverHtml = f.cover_url
                    ? `<img src="${f.cover_url}" alt="${escAttr(f.Name)}" loading="lazy">`
                    : '📁';
                html += `<div class="folder-card" onclick="navigateTo('${f.Slug}')">
                    <div class="folder-cover">${coverHtml}</div>
                    <div class="folder-info">
                        <div class="folder-name">${escHtml(f.Name)}</div>
                        <div class="folder-count">${f.PhotoCount} photo${f.PhotoCount !== 1 ? 's' : ''}</div>
                    </div>
                </div>`;
            }
            html += '</div>';
        }

        if (photos.length === 0 && subfolders.length === 0) {
            html += `<div class="empty-state">
                <div class="icon">📷</div>
                <p>No photos yet${currentUser?.is_admin ? ' — upload some!' : '.'}</p>
            </div>`;
        } else if (photos.length > 0) {
            html += '<div class="photo-grid">';
            photos.forEach((p, i) => {
                const heartClass = p.favorited ? 'heart active' : 'heart';
                html += `<div class="photo-thumb" onclick="openLightbox(${i})">
                    <img src="${p.thumbnail_url}" alt="${escAttr(p.Filename)}" loading="lazy">
                    <div class="photo-overlay">
                        ${currentUser ? `<button class="${heartClass}" onclick="event.stopPropagation(); toggleFavorite(${p.ID}, ${i})">${heartSVG(24)}</button>` : ''}
                        ${currentUser?.is_admin ? `<div class="photo-actions">
                            <button onclick="event.stopPropagation(); setCover(${currentFolder.ID}, ${p.ID})">Cover</button>
                            <button onclick="event.stopPropagation(); deletePhoto(${p.ID})">🗑</button>
                        </div>` : ''}
                    </div>
                </div>`;
            });
            html += '</div>';
        }
        content.innerHTML = html;
    } catch (err) {
        content.innerHTML = `<div class="empty-state"><p>Error loading photos</p></div>`;
    }
}

// Lightbox
let touchStartX = 0;
let touchStartY = 0;
let touchDeltaX = 0;
let swiping = false;
let swipeHandled = false;

function openLightbox(index) {
    lightboxIndex = index;
    showLightboxPhoto();
    const lb = document.getElementById('lightbox');
    lb.classList.remove('hidden');
    document.body.style.overflow = 'hidden';

    // Attach touch handlers to entire lightbox overlay
    lb.addEventListener('touchstart', onLightboxTouchStart, { passive: true });
    lb.addEventListener('touchmove', onLightboxTouchMove, { passive: false });
    lb.addEventListener('touchend', onLightboxTouchEnd, { passive: true });
}

function closeLightbox(e) {
    if (swipeHandled) { swipeHandled = false; return; }
    if (e && e.target !== e.currentTarget) return;
    const lb = document.getElementById('lightbox');
    lb.classList.add('hidden');
    document.body.style.overflow = '';

    lb.removeEventListener('touchstart', onLightboxTouchStart);
    lb.removeEventListener('touchmove', onLightboxTouchMove);
    lb.removeEventListener('touchend', onLightboxTouchEnd);
}

function onLightboxTouchStart(e) {
    if (e.touches.length !== 1) return;
    touchStartX = e.touches[0].clientX;
    touchStartY = e.touches[0].clientY;
    touchDeltaX = 0;
    swiping = false;
}

function onLightboxTouchMove(e) {
    if (e.touches.length !== 1) return;
    const dx = e.touches[0].clientX - touchStartX;
    const dy = e.touches[0].clientY - touchStartY;

    // If horizontal movement is dominant, it's a swipe
    if (!swiping && Math.abs(dx) > 10 && Math.abs(dx) > Math.abs(dy) * 1.5) {
        swiping = true;
    }

    if (swiping) {
        e.preventDefault();
        touchDeltaX = dx;
        const img = document.getElementById('lb-image');
        img.style.transform = `translateX(${dx}px)`;
        img.style.opacity = Math.max(0.3, 1 - Math.abs(dx) / 400);
    }
}

function onLightboxTouchEnd() {
    const img = document.getElementById('lb-image');
    img.style.transform = '';
    img.style.opacity = '';

    if (!swiping) return;

    swipeHandled = true;
    const threshold = 50;
    if (touchDeltaX < -threshold && lightboxIndex < currentPhotos.length - 1) {
        nextPhoto();
    } else if (touchDeltaX > threshold && lightboxIndex > 0) {
        prevPhoto();
    }
    swiping = false;
    touchDeltaX = 0;
}

function showLightboxPhoto() {
    const photo = currentPhotos[lightboxIndex];
    if (!photo) return;
    document.getElementById('lb-image').src = photo.original_url;
    const heartClass = photo.favorited ? 'heart active' : 'heart';
    document.getElementById('lb-info').innerHTML = `
        ${currentUser ? `<button class="${heartClass} lb-heart" onclick="toggleFavorite(${photo.ID}, ${lightboxIndex})">${heartSVG(28)}</button>` : ''}
        <span>${escHtml(photo.Filename)}</span>
        <span>${photo.Width}×${photo.Height}</span>
        <a href="${photo.original_url}" target="_blank" download>Download</a>
        ${currentUser?.is_admin ? `<button class="btn btn-danger btn-small" onclick="deletePhoto(${photo.ID}); closeLightbox();">Delete</button>` : ''}
    `;
}

function prevPhoto(e) {
    if (e) { e.stopPropagation(); e.preventDefault(); }
    if (lightboxIndex > 0) {
        lightboxIndex--;
        showLightboxPhoto();
    }
}

function nextPhoto(e) {
    if (e) { e.stopPropagation(); e.preventDefault(); }
    if (lightboxIndex < currentPhotos.length - 1) {
        lightboxIndex++;
        showLightboxPhoto();
    }
}

// Upload
function openUploadModal() {
    pendingFiles = [];
    document.getElementById('upload-preview').innerHTML = '';
    document.getElementById('upload-progress').classList.add('hidden');
    document.getElementById('btn-upload').disabled = true;
    document.getElementById('file-input').value = '';
    document.getElementById('upload-modal').classList.remove('hidden');
}

function closeUploadModal() {
    document.getElementById('upload-modal').classList.add('hidden');
}

function handleFiles(fileList) {
    pendingFiles = Array.from(fileList).filter(f => f.type.startsWith('image/'));
    const preview = document.getElementById('upload-preview');
    preview.innerHTML = '';

    pendingFiles.forEach(file => {
        const img = document.createElement('img');
        img.className = 'thumb';
        img.src = URL.createObjectURL(file);
        preview.appendChild(img);
    });

    document.getElementById('btn-upload').disabled = pendingFiles.length === 0;
}

async function startUpload() {
    if (!currentFolder || pendingFiles.length === 0) return;

    const btn = document.getElementById('btn-upload');
    btn.disabled = true;
    const progressDiv = document.getElementById('upload-progress');
    progressDiv.classList.remove('hidden');

    const formData = new FormData();
    pendingFiles.forEach(f => formData.append('photos', f));

    try {
        const xhr = new XMLHttpRequest();
        xhr.open('POST', `/api/folders/${currentFolder.ID}/photos`);

        xhr.upload.onprogress = (e) => {
            if (e.lengthComputable) {
                const pct = Math.round((e.loaded / e.total) * 100);
                document.getElementById('progress-fill').style.width = pct + '%';
                document.getElementById('progress-text').textContent = `Uploading... ${pct}%`;
            }
        };

        await new Promise((resolve, reject) => {
            xhr.onload = () => {
                if (xhr.status >= 200 && xhr.status < 300) {
                    resolve(JSON.parse(xhr.responseText));
                } else {
                    reject(new Error('Upload failed'));
                }
            };
            xhr.onerror = () => reject(new Error('Upload failed'));
            xhr.send(formData);
        });

        closeUploadModal();
        await loadPhotos(currentFolder.ID);
    } catch (err) {
        alert('Upload failed: ' + err.message);
        document.getElementById('progress-text').textContent = 'Upload failed';
        btn.disabled = false;
    }
}

// Admin actions
async function promptCreateFolder() {
    const name = prompt('Gallery name:');
    if (!name) return;
    try {
        await api('/api/folders', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name }),
        });
        loadFolders();
    } catch (err) {
        alert('Failed to create gallery: ' + err.message);
    }
}

async function promptCreateSubfolder(parentID) {
    const name = prompt('Subfolder name:');
    if (!name) return;
    try {
        await api('/api/folders', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name, parent_id: parentID }),
        });
        // Reload current folder to show new subfolder
        if (currentFolder) navigateTo(currentFolder.Slug);
    } catch (err) {
        alert('Failed to create subfolder: ' + err.message);
    }
}

async function promptRenameFolder(id, currentName) {
    const name = prompt('Rename gallery:', currentName);
    if (!name || name === currentName) return;
    try {
        const updated = await api(`/api/folders/${id}`, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ name }),
        });
        if (updated.Slug) navigateTo(updated.Slug);
    } catch (err) {
        alert('Failed to rename: ' + err.message);
    }
}

async function promptDeleteFolder(id) {
    if (!confirm('Delete this entire gallery and all photos? This cannot be undone.')) return;
    try {
        await api(`/api/folders/${id}`, { method: 'DELETE' });
        if (currentFolder?.parent) {
            navigateTo(currentFolder.parent.slug);
        } else {
            navigateTo(null);
        }
    } catch (err) {
        alert('Failed to delete: ' + err.message);
    }
}

async function deletePhoto(id) {
    if (!confirm('Delete this photo?')) return;
    try {
        await api(`/api/photos/${id}`, { method: 'DELETE' });
        if (currentFolder) await loadPhotos(currentFolder.ID);
    } catch (err) {
        alert('Failed to delete photo: ' + err.message);
    }
}

async function setCover(folderID, photoID) {
    try {
        await api(`/api/folders/${folderID}/cover`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ photo_id: photoID }),
        });
    } catch (err) {
        alert('Failed to set cover: ' + err.message);
    }
}

// Venmo
async function loadVenmo() {
    try {
        const data = await api('/api/venmo');
        if (data.username) {
            document.getElementById('venmo-fab').classList.remove('hidden');
            document.getElementById('venmo-qr').src = '/api/venmo/qr';
            document.getElementById('venmo-link').href = `https://venmo.com/u/${data.username}`;
        }
    } catch {}
}

// Toggle venmo on mobile
document.querySelector('.venmo-fab-title')?.addEventListener('click', () => {
    if (window.innerWidth <= 768) {
        document.getElementById('venmo-fab').classList.toggle('expanded');
    }
});

document.addEventListener('click', (e) => {
    const fab = document.getElementById('venmo-fab');
    if (fab && fab.classList.contains('expanded') && !fab.contains(e.target)) {
        fab.classList.remove('expanded');
    }
});

// Favorites
async function toggleFavorite(photoID, index) {
    if (!currentUser) return;
    try {
        const data = await api(`/api/photos/${photoID}/favorite`, { method: 'POST' });
        // Update local state
        if (currentPhotos[index]) {
            currentPhotos[index].favorited = data.favorited;
        }
        // Re-render lightbox if open
        if (!document.getElementById('lightbox').classList.contains('hidden')) {
            showLightboxPhoto();
        }
        // Update the heart in the grid
        if (viewingFavorites) {
            loadFavorites(false);
        } else {
            const thumbs = document.querySelectorAll('.photo-thumb');
            if (thumbs[index]) {
                const heart = thumbs[index].querySelector('.heart');
                if (heart) {
                    heart.classList.toggle('active', data.favorited);
                    if (data.favorited) {
                        heart.classList.remove('pop');
                        void heart.offsetWidth; // reflow
                        heart.classList.add('pop');
                    }
                }
            }
        }
    } catch (err) {
        console.error('toggle favorite error:', err);
    }
}

async function loadFavorites(pushState = true) {
    if (!currentUser) return;
    viewingFavorites = true;
    currentFolder = null;
    if (pushState) history.pushState({ favorites: true }, '', '#favorites');

    document.getElementById('nav-breadcrumb').innerHTML = `
        <a href="#" onclick="navigateTo(null); return false;">Home</a>
        <span class="sep">›</span>
        <span>My Favorites</span>
    `;

    const content = document.getElementById('content');
    try {
        const photos = await api('/api/favorites');
        currentPhotos = photos;

        let html = '<div class="section-header"><h2>My Favorites</h2></div>';

        if (photos.length === 0) {
            html += `<div class="empty-state">
                <div class="icon">${heartSVG(48)}</div>
                <p>No favorites yet — click the heart on any photo to save it here.</p>
            </div>`;
        } else {
            html += '<div class="photo-grid">';
            photos.forEach((p, i) => {
                html += `<div class="photo-thumb" onclick="openLightbox(${i})">
                    <img src="${p.thumbnail_url}" alt="${escAttr(p.Filename)}" loading="lazy">
                    <div class="photo-overlay">
                        <button class="heart active" onclick="event.stopPropagation(); toggleFavorite(${p.ID}, ${i})">${heartSVG(24)}</button>
                    </div>
                </div>`;
            });
            html += '</div>';
        }
        content.innerHTML = html;
    } catch (err) {
        content.innerHTML = `<div class="empty-state"><p>Error loading favorites</p></div>`;
    }
}

// Helpers
function heartSVG(size = 24) {
    return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 24 24" fill="currentColor" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>`;
}

function escHtml(s) {
    const div = document.createElement('div');
    div.textContent = s;
    return div.innerHTML;
}

function escAttr(s) {
    return s.replace(/'/g, "\\'").replace(/"/g, '&quot;');
}
