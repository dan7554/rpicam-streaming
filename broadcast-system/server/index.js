const express = require('express');
const http = require('http');
const socketIo = require('socket.io');
const cors = require('cors');
const path = require('path');

// Import services
const CameraManager = require('./services/CameraManager');
const SceneComposer = require('./services/SceneComposer');
const StreamManager = require('./services/StreamManager');
const CommentaryManager = require('./services/CommentaryManager');

// Import routes
const cameraRoutes = require('./routes/cameras');
const sceneRoutes = require('./routes/scenes');
const streamRoutes = require('./routes/streaming');
const configRoutes = require('./routes/config');

class BroadcastServer {
  constructor() {
    this.app = express();
    this.server = http.createServer(this.app);
    this.io = socketIo(this.server, {
      cors: {
        origin: "*",
        methods: ["GET", "POST"]
      }
    });

    this.port = process.env.PORT || 3001;
    this.mediamtxUrl = process.env.MEDIAMTX_URL || 'https://192.168.50.208:8889';
    
    // Initialize services
    this.cameraManager = new CameraManager(this.mediamtxUrl);
    this.sceneComposer = new SceneComposer(this.cameraManager);
    this.streamManager = new StreamManager();
    this.commentaryManager = new CommentaryManager();

    this.setupMiddleware();
    this.setupRoutes();
    this.setupWebSocket();
    this.initializeServices();
  }

  setupMiddleware() {
    this.app.use(cors());
    this.app.use(express.json());
    this.app.use(express.static(path.join(__dirname, '../client/build')));
    
    // Request logging
    this.app.use((req, res, next) => {
      console.log(`${new Date().toISOString()} - ${req.method} ${req.path}`);
      next();
    });
  }

  setupRoutes() {
    // API Routes (nginx handles /api prefix via rewrite)
    this.app.use('/cameras', cameraRoutes(this.cameraManager, this.io));
    this.app.use('/scenes', sceneRoutes(this.sceneComposer, this.io));
    this.app.use('/streaming/streams', streamRoutes(this.streamManager, this.io));
    this.app.use('/config', configRoutes());

    // Health check
    this.app.get('/health', (req, res) => {
      res.json({
        status: 'healthy',
        timestamp: new Date().toISOString(),
        services: {
          cameras: this.cameraManager.getStatus(),
          scenes: this.sceneComposer.getStatus(),
          streaming: this.streamManager.getStatus(),
          commentary: this.commentaryManager.getStatus()
        }
      });
    });

    // Serve React app for all other routes
    this.app.get('*', (req, res) => {
      res.sendFile(path.join(__dirname, '../client/dist/index.html'));
    });
  }

  setupWebSocket() {
    this.io.on('connection', (socket) => {
      console.log(`Client connected: ${socket.id}`);

      // Send initial state
      socket.emit('initial-state', {
        cameras: this.cameraManager.getCameras(),
        currentScene: this.sceneComposer.getCurrentScene(),
        streamStatus: this.streamManager.getStatus(),
        commentaryStatus: this.commentaryManager.getStatus()
      });

      // Camera controls
      socket.on('switch-camera', async (data) => {
        try {
          console.log('🔄 Server received switch-camera event:', data);
          await this.cameraManager.switchCamera(data.cameraId);
          console.log('✅ Camera switched successfully');
          
          this.io.emit('camera-switched', data);
          console.log('📡 Emitted camera-switched event:', data);
          
          // Also emit the preview URL for the new camera
          const streamUrl = this.cameraManager.getPreviewUrl(data.cameraId);
          console.log('🎥 Preview URL for camera', data.cameraId, ':', streamUrl);
          this.io.emit('preview-stream-url', streamUrl);
          console.log('📡 Emitted preview-stream-url:', streamUrl);
        } catch (error) {
          console.error('❌ Failed to switch camera:', error);
          socket.emit('error', { message: 'Failed to switch camera', error: error.message });
        }
      });

      // Scene controls
      socket.on('switch-scene', async (data) => {
        try {
          await this.sceneComposer.switchScene(data.sceneId, data.transition);
          this.io.emit('scene-switched', data);
        } catch (error) {
          socket.emit('error', { message: 'Failed to switch scene', error: error.message });
        }
      });

      // Streaming controls
      socket.on('start-stream', async (data) => {
        try {
          await this.streamManager.startStream(data);
          this.io.emit('stream-started', { status: 'live' });
        } catch (error) {
          socket.emit('error', { message: 'Failed to start stream', error: error.message });
        }
      });

      socket.on('stop-stream', async () => {
        try {
          await this.streamManager.stopStream();
          this.io.emit('stream-stopped', { status: 'offline' });
        } catch (error) {
          socket.emit('error', { message: 'Failed to stop stream', error: error.message });
        }
      });

      // Commentary controls
      socket.on('commentary-start', async (data) => {
        try {
          await this.commentaryManager.startCommentary(data.commentatorId);
          this.io.emit('commentary-started', data);
        } catch (error) {
          socket.emit('error', { message: 'Failed to start commentary', error: error.message });
        }
      });

      socket.on('commentary-stop', async (data) => {
        try {
          await this.commentaryManager.stopCommentary(data.commentatorId);
          this.io.emit('commentary-stopped', data);
        } catch (error) {
          socket.emit('error', { message: 'Failed to stop commentary', error: error.message });
        }
      });

      // Audio level monitoring
      socket.on('audio-level', (data) => {
        this.io.emit('audio-level', data);
      });

      // Preview controls
      socket.on('preview-camera', (data) => {
        const streamUrl = this.cameraManager.getPreviewUrl(data.cameraId);
        socket.emit('preview-stream-url', streamUrl);
      });

      // Get current preview stream
      socket.on('get-preview-stream', () => {
        console.log('🎥 Server received get-preview-stream request');
        // Get the first active camera or any available camera
        const cameras = this.cameraManager.getCameras();
        const activeCamera = cameras.find(cam => cam.status === 'online');
        
        if (activeCamera) {
          const streamUrl = this.cameraManager.getPreviewUrl(activeCamera.id);
          console.log('✅ Found active camera:', activeCamera.id, 'URL:', streamUrl);
          socket.emit('preview-stream-url', streamUrl);
          
          // Also emit initial stats if available
          this.getCameraStats(activeCamera.id).then(stats => {
            if (stats) {
              socket.emit('preview-stats', stats);
            }
          });
        } else {
          console.log('❌ No active cameras available');
          socket.emit('preview-error', 'No active cameras available');
        }
      });

      // Request preview stats for current camera
      socket.on('get-preview-stats', (cameraId) => {
        this.getCameraStats(cameraId || null).then(stats => {
          if (stats) {
            socket.emit('preview-stats', stats);
          }
        });
      });

      // Preview quality and stream controls
      socket.on('change-preview-quality', (quality) => {
        console.log('🎛️ Changing preview quality to:', quality);
        // This could be implemented to request different quality streams
        // For now, just acknowledge the request
        socket.emit('preview-quality-changed', quality);
      });

      socket.on('refresh-preview-stream', () => {
        console.log('🔄 Refreshing preview stream');
        // Re-emit the current preview stream URL
        const cameras = this.cameraManager.getCameras();
        const activeCamera = cameras.find(cam => cam.status === 'online');
        if (activeCamera) {
          const streamUrl = this.cameraManager.getPreviewUrl(activeCamera.id);
          socket.emit('preview-stream-url', streamUrl);
        }
      });

      socket.on('get-scene-preview', (sceneId) => {
        console.log('🎬 Getting scene preview for:', sceneId);
        // Get the composed scene stream URL
        if (this.sceneComposer) {
          const sceneStreamUrl = this.sceneComposer.getSceneStreamUrl(sceneId);
          if (sceneStreamUrl) {
            socket.emit('preview-stream-url', sceneStreamUrl);
          } else {
            // Fallback to active camera if scene not available
            const cameras = this.cameraManager.getCameras();
            const activeCamera = cameras.find(cam => cam.status === 'online');
            if (activeCamera) {
              const streamUrl = this.cameraManager.getPreviewUrl(activeCamera.id);
              socket.emit('preview-stream-url', streamUrl);
            }
          }
        }
      });

      socket.on('get-stream-settings', () => {
        console.log('⚙️ Getting stream settings');
        // Return current stream settings
        const cameras = this.cameraManager.getCameras();
        const activeCamera = cameras.find(cam => cam.status === 'online');
        const settings = {
          quality: '1080p',
          bitrate: activeCamera?.settings?.bitrate || 3000,
          framerate: activeCamera?.settings?.framerate || 30,
          resolution: activeCamera?.settings?.resolution || '1920x1080'
        };
        socket.emit('stream-settings', settings);
      });

      socket.on('get-advanced-settings', () => {
        console.log('🔧 Getting advanced settings');
        // Return advanced configuration options
        const advancedSettings = {
          codec: 'h264',
          profile: 'high',
          latency: 'low',
          keyframes: 30,
          bufferSize: 1000
        };
        socket.emit('advanced-settings', advancedSettings);
      });

      // Commentary controls
      socket.on('toggle-microphone', (enabled) => {
        console.log('🎤 Toggling microphone:', enabled);
        this.io.emit('microphone-toggled', { enabled, socketId: socket.id });
      });

      socket.on('set-commentary-volume', (volume) => {
        console.log('🔊 Setting commentary volume:', volume);
        this.io.emit('commentary-volume-changed', { volume, socketId: socket.id });
      });

      socket.on('start-commentary-recording', () => {
        console.log('🎙️ Starting commentary recording');
        this.io.emit('commentary-recording-started', { socketId: socket.id });
      });

      socket.on('stop-commentary-recording', () => {
        console.log('⏹️ Stopping commentary recording');
        this.io.emit('commentary-recording-stopped', { socketId: socket.id });
      });

      socket.on('toggle-commentary', (enabled) => {
        console.log('📺 Toggling commentary:', enabled);
        this.io.emit('commentary-toggled', { enabled, socketId: socket.id });
      });

      socket.on('get-system-stats', () => {
        console.log('📊 Getting system stats');
        const systemStats = this.getComprehensiveSystemStats();
        socket.emit('system-stats', systemStats);
      });

      // Disconnect handling
      socket.on('disconnect', () => {
        console.log(`Client disconnected: ${socket.id}`);
      });
    });
  }

  async initializeServices() {
    try {
      // Initialize camera manager
      await this.cameraManager.initialize();
      console.log('Camera Manager initialized');

      // Initialize scene composer
      await this.sceneComposer.initialize();
      console.log('Scene Composer initialized');

      // Initialize stream manager
      await this.streamManager.initialize();
      console.log('Stream Manager initialized');

      // Initialize commentary manager
      await this.commentaryManager.initialize();
      console.log('Commentary Manager initialized');

      // Start monitoring services
      this.startMonitoring();

    } catch (error) {
      console.error('Failed to initialize services:', error);
      process.exit(1);
    }
  }

  async getCameraStats(cameraId) {
    try {
      if (!cameraId) {
        // Get stats for the first active camera
        const cameras = this.cameraManager.getCameras();
        const activeCamera = cameras.find(cam => cam.status === 'online');
        if (!activeCamera) return null;
        cameraId = activeCamera.id;
      }

      const stats = await this.cameraManager.getCameraStats(cameraId);
      return stats;
    } catch (error) {
      console.error('Failed to get camera stats:', error);
      return null;
    }
  }

  startMonitoring() {
    // Monitor camera health every 30 seconds
    setInterval(async () => {
      const cameraStatus = await this.cameraManager.checkHealth();
      this.io.emit('camera-health', cameraStatus);
      
      // Also emit individual camera status changes
      const cameras = this.cameraManager.getCameras();
      this.io.emit('cameras-updated', cameras);
      
      // Emit status changes for each camera
      cameras.forEach(camera => {
        this.io.emit('camera-status-changed', camera.id, camera.status);
      });
    }, 30000);

    // Monitor stream health every 10 seconds
    setInterval(async () => {
      const streamStatus = await this.streamManager.getDetailedStatus();
      this.io.emit('stream-health', streamStatus);
    }, 10000);

    // Monitor preview stats every 5 seconds
    setInterval(async () => {
      const cameras = this.cameraManager.getCameras();
      const activeCamera = cameras.find(cam => cam.status === 'online');
      if (activeCamera) {
        const stats = await this.getCameraStats(activeCamera.id);
        if (stats) {
          this.io.emit('preview-stats', stats);
        }
      }
    }, 5000);

    // Monitor commentary stats every 2 seconds
    setInterval(() => {
      const commentaryStats = this.commentaryManager.getStats();
      this.io.emit('commentary-stats', commentaryStats);
    }, 2000);

    // Monitor system resources every 60 seconds
    setInterval(() => {
      const systemStats = this.getComprehensiveSystemStats();
      this.io.emit('system-stats', systemStats);
    }, 60000);
  }

  getComprehensiveSystemStats() {
    const cameras = this.cameraManager.getCameras();
    const onlineCameras = cameras.filter(cam => cam.status === 'online').length;
    const offlineCameras = cameras.filter(cam => cam.status === 'offline').length;
    
    const memory = process.memoryUsage();
    const os = require('os');
    const { execSync } = require('child_process');
    
    // Get system memory based on OS
    let totalSystemMemory = os.totalmem();
    let freeSystemMemory = os.freemem();
    let usedSystemMemory = totalSystemMemory - freeSystemMemory;
    let systemMemoryPercent = (usedSystemMemory / totalSystemMemory) * 100;
    
    try {
      const platform = os.platform();
      
      if (platform === 'darwin') {
        // macOS - use vm_stat for more accurate memory info
        const vmStat = execSync('vm_stat').toString();
        const pageSize = 16384; // macOS uses 16KB pages on Apple Silicon, 4KB on Intel
        
        // Parse vm_stat output
        const freePages = parseInt(vmStat.match(/Pages free:\s+(\d+)/)?.[1] || '0');
        const activePages = parseInt(vmStat.match(/Pages active:\s+(\d+)/)?.[1] || '0');
        const inactivePages = parseInt(vmStat.match(/Pages inactive:\s+(\d+)/)?.[1] || '0');
        const speculativePages = parseInt(vmStat.match(/Pages speculative:\s+(\d+)/)?.[1] || '0');
        const wiredPages = parseInt(vmStat.match(/Pages wired down:\s+(\d+)/)?.[1] || '0');
        const compressedPages = parseInt(vmStat.match(/Pages stored in compressor:\s+(\d+)/)?.[1] || '0');
        
        // Calculate memory usage
        const totalPages = freePages + activePages + inactivePages + speculativePages + wiredPages + compressedPages;
        const usedPages = activePages + inactivePages + wiredPages + compressedPages;
        
        totalSystemMemory = totalPages * pageSize;
        usedSystemMemory = usedPages * pageSize;
        freeSystemMemory = freePages * pageSize;
        systemMemoryPercent = (usedSystemMemory / totalSystemMemory) * 100;
        
      } else if (platform === 'linux') {
        // Linux - use /proc/meminfo for accurate memory info
        const meminfo = execSync('cat /proc/meminfo').toString();
        
        const totalKB = parseInt(meminfo.match(/MemTotal:\s+(\d+)/)?.[1] || '0');
        const freeKB = parseInt(meminfo.match(/MemFree:\s+(\d+)/)?.[1] || '0');
        const buffersKB = parseInt(meminfo.match(/Buffers:\s+(\d+)/)?.[1] || '0');
        const cachedKB = parseInt(meminfo.match(/Cached:\s+(\d+)/)?.[1] || '0');
        const availableKB = parseInt(meminfo.match(/MemAvailable:\s+(\d+)/)?.[1] || '0');
        
        // Calculate actual used memory (excluding buffers/cache)
        totalSystemMemory = totalKB * 1024;
        const actuallyFreeMemory = availableKB > 0 ? availableKB * 1024 : (freeKB + buffersKB + cachedKB) * 1024;
        usedSystemMemory = totalSystemMemory - actuallyFreeMemory;
        freeSystemMemory = actuallyFreeMemory;
        systemMemoryPercent = (usedSystemMemory / totalSystemMemory) * 100;
      }
      // For other platforms (Windows, etc.), fall back to os.totalmem()/os.freemem()
      
    } catch (error) {
      console.warn('Failed to get OS-specific memory info, using Node.js os module:', error.message);
      // Fallback to os module values already calculated above
    }
    
    // Node.js process memory info for debugging
    const nodeMemoryUsedMB = memory.rss / 1024 / 1024; // RSS = Resident Set Size (actual memory used by Node.js)

    return {
      cameras: {
        total: cameras.length,
        online: onlineCameras,
        offline: offlineCameras
      },
      streams: {
        active: onlineCameras, // Assuming each online camera has an active stream
        viewers: 0, // Would need to be tracked separately
        bytesTransferred: 0 // Would need to be tracked separately
      },
      system: {
        platform: os.platform(),
        arch: os.arch(),
        cpu: Math.random() * 20 + 10, // Simulated CPU usage 10-30%
        cpuAverage: Math.random() * 15 + 5, // Simulated average
        cores: require('os').cpus().length,
        memory: Math.round(systemMemoryPercent * 100) / 100, // Round to 2 decimal places
        memoryUsed: usedSystemMemory, // System memory used
        memoryTotal: totalSystemMemory, // Total system memory
        memoryFree: freeSystemMemory, // Free system memory
        nodeMemoryMB: Math.round(nodeMemoryUsedMB * 100) / 100, // Node.js process memory for debugging
        networkOut: Math.random() * 1024 * 1024, // Simulated network out
        networkIn: Math.random() * 512 * 1024, // Simulated network in
        totalNetworkOut: Math.random() * 1024 * 1024 * 1024, // Simulated total
        uptime: process.uptime(),
        serviceUptime: process.uptime(),
        startTime: new Date(Date.now() - process.uptime() * 1000).toISOString()
      },
      timestamp: new Date().toISOString()
    };
  }

  start() {
    this.server.listen(this.port, () => {
      console.log(`🎥 Racetrack Broadcast System running on port ${this.port}`);
      console.log(`📡 MediaMTX URL: ${this.mediamtxUrl}`);
      console.log(`🌐 Admin Dashboard: http://localhost:${this.port}`);
      console.log(`🔧 API Base URL: http://localhost:${this.port}/api`);
      console.log(`🎛️  WebSocket: http://localhost:${this.port}`);
    });
  }

  // Graceful shutdown
  shutdown() {
    console.log('Shutting down broadcast server...');
    
    // Stop all services
    this.streamManager.stopAllStreams();
    this.commentaryManager.stopAllCommentary();
    this.cameraManager.disconnect();
    
    // Close server
    this.server.close(() => {
      console.log('Server closed');
      process.exit(0);
    });
  }
}

// Handle graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received');
  if (global.broadcastServer) {
    global.broadcastServer.shutdown();
  }
});

process.on('SIGINT', () => {
  console.log('SIGINT received');
  if (global.broadcastServer) {
    global.broadcastServer.shutdown();
  }
});

// Start the server
const server = new BroadcastServer();
global.broadcastServer = server;
server.start();

module.exports = BroadcastServer;