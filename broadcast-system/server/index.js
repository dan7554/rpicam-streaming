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
    this.sceneComposer = new SceneComposer();
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
    // API Routes
    this.app.use('/api/cameras', cameraRoutes(this.cameraManager, this.io));
    this.app.use('/api/scenes', sceneRoutes(this.sceneComposer, this.io));
    this.app.use('/api/streaming/streams', streamRoutes(this.streamManager, this.io));
    this.app.use('/api/config', configRoutes());

    // Health check
    this.app.get('/api/health', (req, res) => {
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
      res.sendFile(path.join(__dirname, '../client/build/index.html'));
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
      const systemStats = {
        memory: process.memoryUsage(),
        cpu: process.cpuUsage(),
        uptime: process.uptime(),
        timestamp: new Date().toISOString()
      };
      this.io.emit('system-stats', systemStats);
    }, 60000);
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