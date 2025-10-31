const axios = require('axios');
const { v4: uuidv4 } = require('uuid');

class CameraManager {
  constructor(mediamtxUrl) {
    this.mediamtxUrl = mediamtxUrl;
    this.cameras = new Map();
    this.activeCameras = new Set();
    this.previewCache = new Map();
    this.healthCheckInterval = null;
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
      
      try {
        const configData = await fs.readFile(configPath, 'utf8');
        const config = JSON.parse(configData);
        
        for (const camera of config.cameras) {
          this.addCamera(camera);
        }
      } catch (error) {
        // If config doesn't exist, create a default one
        if (error.code === 'ENOENT') {
          await this.createDefaultConfig(configPath);
        } else {
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
      const response = await axios.get(`${this.mediamtxUrl}/v3/paths/list`);
      const paths = response.data.items || {};
      
      for (const [pathName, pathInfo] of Object.entries(paths)) {
        // Check if we already have this camera configured
        if (!this.cameras.has(pathName)) {
          // Auto-discover new camera
          const discoveredCamera = {
            id: pathName,
            name: `Auto-discovered: ${pathName}`,
            type: 'webrtc',
            url: `${this.mediamtxUrl.replace('8888', '8889')}/${pathName}/whep`,
            rtspUrl: `${this.mediamtxUrl.replace('http', 'rtsp').replace('8888', '8554')}/${pathName}`,
            enabled: true,
            autodiscovered: true,
            position: { x: 0, y: 0, width: 1920, height: 1080 }
          };
          
          this.addCamera(discoveredCamera);
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
      status: 'disconnected',
      lastSeen: null,
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
    return Array.from(this.cameras.values());
  }

  getCamera(cameraId) {
    return this.cameras.get(cameraId);
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
        return camera.rtspUrl;
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
      // For WebRTC cameras, check if the path exists in MediaMTX
      if (camera.type === 'webrtc') {
        const pathName = camera.url.split('/').slice(-2, -1)[0];
        const response = await axios.get(`${this.mediamtxUrl}/v3/paths/get/${pathName}`);
        const isActive = response.data.sourceReady === true;
        
        camera.status = isActive ? 'connected' : 'disconnected';
        camera.lastSeen = new Date().toISOString();
        
        return isActive;
      }

      // For other camera types, implement appropriate health checks
      return true;
      
    } catch (error) {
      camera.status = 'error';
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
      await this.checkHealth();
    }, 30000); // Check every 30 seconds
  }

  getStatus() {
    return {
      totalCameras: this.cameras.size,
      activeCameras: this.activeCameras.size,
      connectedCameras: Array.from(this.cameras.values()).filter(c => c.status === 'connected').length,
      mediamtxUrl: this.mediamtxUrl
    };
  }

  // Get camera stream statistics
  async getCameraStats(cameraId) {
    const camera = this.cameras.get(cameraId);
    if (!camera) return null;

    try {
      if (camera.type === 'webrtc') {
        const pathName = camera.url.split('/').slice(-2, -1)[0];
        const response = await axios.get(`${this.mediamtxUrl}/v3/paths/get/${pathName}`);
        const pathData = response.data;

        return {
          bitrate: pathData.bytesReceived || 0,
          readers: pathData.readers || 0,
          sourceReady: pathData.sourceReady || false,
          lastUpdate: new Date().toISOString()
        };
      }
    } catch (error) {
      console.error(`Failed to get stats for camera ${cameraId}:`, error.message);
    }

    return null;
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