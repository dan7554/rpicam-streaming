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

    this.port = process.env.PORT || 3000;
    this.mediamtxUrl = process.env.MEDIAMTX_URL || 'http://localhost:8888';
    
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
    this.app.use('/api/stream', streamRoutes(this.streamManager, this.io));
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
          await this.cameraManager.switchCamera(data.cameraId);
          this.io.emit('camera-switched', data);
        } catch (error) {
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
        this.io.emit('audio-level-update', data);
      });

      // Preview controls
      socket.on('preview-camera', (data) => {
        socket.emit('preview-update', {
          cameraId: data.cameraId,
          streamUrl: this.cameraManager.getPreviewUrl(data.cameraId)
        });
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

  startMonitoring() {
    // Monitor camera health every 30 seconds
    setInterval(async () => {
      const cameraStatus = await this.cameraManager.checkHealth();
      this.io.emit('camera-health', cameraStatus);
    }, 30000);

    // Monitor stream health every 10 seconds
    setInterval(async () => {
      const streamStatus = await this.streamManager.getDetailedStatus();
      this.io.emit('stream-health', streamStatus);
    }, 10000);

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