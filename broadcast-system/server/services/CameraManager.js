const axios = require('axios');
const https = require('https');
const { v4: uuidv4 } = require('uuid');

class CameraManager {
  constructor(mediamtxUrl) {
    this.mediamtxUrl = mediamtxUrl;
    
    // Resolve MediaMTX API and host from environment or derived from mediamtxUrl
    const mediaUrl = new URL(mediamtxUrl);
    const mediaHost = process.env.MEDIAMTX_HOST || mediaUrl.hostname;
    const mediaPort = process.env.MEDIAMTX_API_PORT || '9997';
    const mediaProtocol = process.env.MEDIAMTX_API_PROTOCOL || mediaUrl.protocol.replace(':', '');
    
    this.mediamtxApiUrl = process.env.MEDIAMTX_API_URL || `${mediaProtocol}://${mediaHost}:${mediaPort}`;
    this.mediamtxHost = mediaHost;
    // Use BROADCAST_URL for client-facing WebRTC URLs (avoids mixed content errors)
    this.broadcastUrl = process.env.BROADCAST_URL || null;
    this.cameras = new Map();
    this.activeCameras = new Set();
    this.previewCache = new Map();
    this.healthCheckInterval = null;
    this.newCamerasDiscovered = false; // Track if new cameras were discovered
    
    // Configure axios to handle self-signed certificates
    this.axiosConfig = {
      httpsAgent: new https.Agent({
        rejectUnauthorized: false // Accept self-signed certificates
      }),
      timeout: 5000
    };
  }

  async initialize() {
    // Load camera configuration
    await this.loadCameraConfig();
    
    // Start health monitoring
    this.startHealthMonitoring();
    
    // Discover existing MediaMTX paths
    await this.discoverExistingStreams();
  }

  async loadCameraConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/cameras.json');
      
      console.log(`🔍 Loading camera config from: ${configPath}`);
      
      try {
        const configData = await fs.readFile(configPath, 'utf8');
        const config = JSON.parse(configData);
        
        console.log(`📚 Config loaded successfully. Found ${config.cameras?.length || 0} cameras`);
        
        for (const camera of config.cameras) {
          console.log(`   ✅ Adding camera: ${camera.name} (${camera.id})`);
          this.addCamera(camera);
        }
      } catch (error) {
        // If config doesn't exist, create a default one
        if (error.code === 'ENOENT') {
          console.log(`⚠️  Config file not found at ${configPath}, creating default`);
          await this.createDefaultConfig(configPath);
        } else {
          console.error(`❌ Error reading config: ${error.message}`);
          throw error;
        }
      }
    } catch (error) {
      console.error('Failed to load camera config:', error);
      // Continue with empty camera list
    }
  }

  async createDefaultConfig(configPath) {
    const defaultConfig = {
      cameras: [
        {
          id: 'rpicam',
          name: 'Raspberry Pi Camera',
          type: 'webrtc',
          url: `${this.mediamtxUrl.replace('8888', '8889')}/rpicam/whep`,
          rtspUrl: `${this.mediamtxUrl.replace('http', 'rtsp').replace('8888', '8554')}/rpicam`,
          enabled: true,
          position: { x: 0, y: 0, width: 1920, height: 1080 },
          settings: {
            resolution: '1920x1080',
            framerate: 30,
            bitrate: 5000
          }
        }
      ]
    };

    const fs = require('fs').promises;
    const path = require('path');
    
    // Ensure config directory exists
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    
    // Write default config
    await fs.writeFile(configPath, JSON.stringify(defaultConfig, null, 2));
    
    // Load the default cameras
    for (const camera of defaultConfig.cameras) {
      this.addCamera(camera);
    }
  }

  async discoverExistingStreams() {
    try {
      const response = await axios.get(`${this.mediamtxApiUrl}/v3/paths/list`, this.axiosConfig);
      const paths = response.data.items || [];
      
      console.log(`🔍 Auto-discovery found ${paths.length} active MediaMTX paths`);
      
      // The response is now an array of path objects, not a key-value object
      for (const pathInfo of paths) {
        const pathName = pathInfo.name;
        
        // Check if we already have this camera configured
        if (!this.cameras.has(pathName)) {
          // Auto-discover new camera
          // WebRTC via NLB with TLS termination on port 443 (using ACM certificate)
          // NLB forwards to MediaMTX port 8889 for actual WebRTC signaling
          const webrtcUrl = `https://mediamtx.racetrackstreaming.com/${pathName}`;
          
          const discoveredCamera = {
            id: pathName,
            name: `${pathName}`,
            type: 'webrtc',
            url: webrtcUrl,
            rtspUrl: `rtsp://${this.mediamtxHost}:8554/${pathName}`,
            enabled: true,
            autodiscovered: true,
            position: { x: 0, y: 0, width: 1920, height: 1080 },
            status: pathInfo.ready ? 'online' : 'offline',
            lastSeen: pathInfo.readyTime || new Date().toISOString()
          };
          
          console.log(`✅ Auto-discovered camera: ${pathName} (${pathInfo.ready ? 'online' : 'offline'})`);
          this.addCamera(discoveredCamera);
          this.newCamerasDiscovered = true; // Flag that new cameras were found
        } else {
          // Update existing camera status
          const camera = this.cameras.get(pathName);
          if (camera && camera.autodiscovered) {
            const newStatus = pathInfo.ready ? 'online' : 'offline';
            
            // Log status changes
            if (camera.status !== newStatus) {
              console.log(`🔄 Camera ${pathName}: ${camera.status} → ${newStatus}`);
            }
            
            camera.status = newStatus;
            camera.lastSeen = pathInfo.readyTime || new Date().toISOString();
          }
        }
      }
    } catch (error) {
      console.error('Failed to discover existing streams:', error.message);
    }
  }

  addCamera(cameraConfig) {
    const camera = {
      id: cameraConfig.id || uuidv4(),
      name: cameraConfig.name,
      type: cameraConfig.type || 'webrtc',
      url: cameraConfig.url,
      rtspUrl: cameraConfig.rtspUrl,
      enabled: cameraConfig.enabled !== false,
      position: cameraConfig.position || { x: 0, y: 0, width: 1920, height: 1080 },
      settings: cameraConfig.settings || {},
      status: cameraConfig.status || 'offline',
      lastSeen: cameraConfig.lastSeen || null,
      bitrate: 0,
      framerate: 0,
      resolution: '',
      autodiscovered: cameraConfig.autodiscovered || false
    };

    this.cameras.set(camera.id, camera);
    return camera.id;
  }

  removeCamera(cameraId) {
    this.activeCameras.delete(cameraId);
    this.previewCache.delete(cameraId);
    return this.cameras.delete(cameraId);
  }

  updateCamera(cameraId, updates) {
    const camera = this.cameras.get(cameraId);
    if (camera) {
      Object.assign(camera, updates);
      this.cameras.set(cameraId, camera);
      return camera;
    }
    return null;
  }

  getCameras() {
    return Array.from(this.cameras.values()).map(camera => ({
      ...camera,
      previewUrl: this.getPreviewUrl(camera.id)
    }));
  }

  getCamera(cameraId) {
    const camera = this.cameras.get(cameraId);
    if (!camera) return null;
    
    return {
      ...camera,
      previewUrl: this.getPreviewUrl(cameraId)
    };
  }

  async switchCamera(cameraId) {
    const camera = this.cameras.get(cameraId);
    if (!camera) {
      throw new Error(`Camera ${cameraId} not found`);
    }

    if (!camera.enabled) {
      throw new Error(`Camera ${cameraId} is disabled`);
    }

    // Check if camera is healthy
    const isHealthy = await this.checkCameraHealth(cameraId);
    if (!isHealthy) {
      throw new Error(`Camera ${cameraId} is not responding`);
    }

    this.activeCameras.add(cameraId);
    camera.lastSeen = new Date().toISOString();
    camera.status = 'active';

    return camera;
  }

  getPreviewUrl(cameraId) {
    const camera = this.cameras.get(cameraId);
    if (!camera) return null;

    // Return appropriate preview URL based on camera type
    switch (camera.type) {
      case 'webrtc':
        return camera.url;
      case 'rtsp':
        return camera.rtspUrl || camera.url;
      case 'hls':
        return camera.url;
      default:
        return camera.url;
    }
  }

  async checkCameraHealth(cameraId) {
    const camera = this.cameras.get(cameraId);
    if (!camera) return false;

    try {
      // Auto-discovered cameras are updated by discoverExistingStreams()
      // Skip health check to avoid redundant API calls
      if (camera.autodiscovered) {
        return camera.status === 'online';
      }

      // For manually configured cameras, check MediaMTX API
      // Extract path name from camera ID (which is the MediaMTX path for auto-discovered)
      // or from the URL for manual configs
      const pathName = camera.id;
      const response = await axios.get(`${this.mediamtxApiUrl}/v3/paths/get/${pathName}`, this.axiosConfig);
      const isActive = response.data.ready === true;
      
      camera.status = isActive ? 'online' : 'offline';
      camera.lastSeen = new Date().toISOString();
      
      return isActive;
      
    } catch (error) {
      camera.status = 'error';
      console.error(`Health check failed for camera ${cameraId}:`, error.message);
      return false;
    }
  }

  async checkHealth() {
    const healthResults = {};
    
    for (const [cameraId, camera] of this.cameras.entries()) {
      healthResults[cameraId] = {
        ...camera,
        healthy: await this.checkCameraHealth(cameraId)
      };
    }

    return healthResults;
  }

  startHealthMonitoring() {
    this.healthCheckInterval = setInterval(async () => {
      // Check camera health and auto-discover new streams
      await this.checkHealth();
      await this.discoverExistingStreams();
    }, 10000); // Check every 10 seconds for faster updates and discovery
  }

  getStatus() {
    return {
      totalCameras: this.cameras.size,
      activeCameras: this.activeCameras.size,
      connectedCameras: Array.from(this.cameras.values()).filter(c => c.status === 'online').length,
      mediamtxUrl: this.mediamtxUrl,
      mediamtxApiUrl: this.mediamtxApiUrl
    };
  }

  // Get camera stream statistics
  async getCameraStats(cameraId) {
    const camera = this.cameras.get(cameraId);
    if (!camera) return null;

    try {
      if (camera.type === 'webrtc') {
        const pathName = camera.url.split('/').slice(-2, -1)[0];
        const response = await axios.get(`${this.mediamtxApiUrl}/v3/paths/get/${pathName}`, this.axiosConfig);
        const pathData = response.data;

        return {
          bitrate: pathData.bytesReceived || 0,
          readers: pathData.readers || 0,
          ready: pathData.ready || false,
          lastUpdate: new Date().toISOString()
        };
      }
    } catch (error) {
      console.error(`Failed to get stats for camera ${cameraId}:`, error.message);
    }

    return null;
  }

  // Check if new cameras were discovered and reset the flag
  hasNewCameras() {
    const hasNew = this.newCamerasDiscovered;
    this.newCamerasDiscovered = false; // Reset flag after checking
    return hasNew;
  }

  // Save current configuration
  async saveConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/cameras.json');
      
      const config = {
        cameras: Array.from(this.cameras.values()).filter(camera => !camera.autodiscovered)
      };

      await fs.writeFile(configPath, JSON.stringify(config, null, 2));
      return true;
    } catch (error) {
      console.error('Failed to save camera config:', error);
      return false;
    }
  }

  disconnect() {
    if (this.healthCheckInterval) {
      clearInterval(this.healthCheckInterval);
    }
  }
}

module.exports = CameraManager;