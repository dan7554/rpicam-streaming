const ffmpeg = require('fluent-ffmpeg');
const { v4: uuidv4 } = require('uuid');

class StreamManager {
  constructor() {
    this.streams = new Map();
    this.activeStreams = new Set();
    this.streamProcesses = new Map();
    this.streamStats = new Map();
    this.monitoringInterval = null;
  }

  async initialize() {
    await this.loadStreamConfig();
    this.startMonitoring();
  }

  async loadStreamConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/streaming.json');
      
      try {
        const configData = await fs.readFile(configPath, 'utf8');
        const config = JSON.parse(configData);
        
        for (const stream of config.streams) {
          this.addStream(stream);
        }
      } catch (error) {
        if (error.code === 'ENOENT') {
          await this.createDefaultStreamConfig(configPath);
        } else {
          throw error;
        }
      }
    } catch (error) {
      console.error('Failed to load stream config:', error);
    }
  }

  async createDefaultStreamConfig(configPath) {
    const defaultConfig = {
      streams: [
        {
          id: 'youtube-main',
          name: 'YouTube Live Main',
          type: 'rtmp',
          url: 'rtmp://a.rtmp.youtube.com/live2/',
          streamKey: '', // To be filled by user
          enabled: false,
          settings: {
            resolution: '1920x1080',
            framerate: 30,
            videoBitrate: 6000,
            audioBitrate: 128,
            audioSampleRate: 44100,
            preset: 'veryfast',
            profile: 'main',
            level: '4.1'
          }
        },
        {
          id: 'youtube-backup',
          name: 'YouTube Live Backup',
          type: 'rtmp',
          url: 'rtmp://a.rtmp.youtube.com/live2/',
          streamKey: '', // To be filled by user
          enabled: false,
          settings: {
            resolution: '1280x720',
            framerate: 30,
            videoBitrate: 3000,
            audioBitrate: 128,
            audioSampleRate: 44100,
            preset: 'fast',
            profile: 'main',
            level: '3.1'
          }
        },
        {
          id: 'facebook-live',
          name: 'Facebook Live',
          type: 'rtmp',
          url: 'rtmps://live-api-s.facebook.com:443/rtmp/',
          streamKey: '', // To be filled by user
          enabled: false,
          settings: {
            resolution: '1920x1080',
            framerate: 30,
            videoBitrate: 4000,
            audioBitrate: 128,
            audioSampleRate: 44100,
            preset: 'fast',
            profile: 'main',
            level: '4.0'
          }
        },
        {
          id: 'mediamtx-output',
          name: 'MediaMTX Re-stream',
          type: 'rtmp',
          url: 'rtmp://localhost:1935/live',
          streamKey: '',
          enabled: true,
          settings: {
            resolution: '1920x1080',
            framerate: 30,
            videoBitrate: 5000,
            audioBitrate: 128,
            audioSampleRate: 44100,
            preset: 'veryfast',
            profile: 'main',
            level: '4.1'
          }
        }
      ]
    };

    const fs = require('fs').promises;
    const path = require('path');
    
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    await fs.writeFile(configPath, JSON.stringify(defaultConfig, null, 2));
    
    for (const stream of defaultConfig.streams) {
      this.addStream(stream);
    }
  }

  addStream(streamConfig) {
    const stream = {
      id: streamConfig.id || uuidv4(),
      name: streamConfig.name,
      type: streamConfig.type || 'rtmp',
      url: streamConfig.url,
      streamKey: streamConfig.streamKey || '',
      enabled: streamConfig.enabled !== false,
      settings: streamConfig.settings || this.getDefaultSettings(),
      status: 'stopped',
      startTime: null,
      lastError: null,
      retryCount: 0,
      maxRetries: 3,
      health: {
        connected: false,
        bitrate: 0,
        droppedFrames: 0,
        uptime: 0
      }
    };

    this.streams.set(stream.id, stream);
    return stream.id;
  }

  getDefaultSettings() {
    return {
      resolution: '1920x1080',
      framerate: 30,
      videoBitrate: 5000,
      audioBitrate: 128,
      audioSampleRate: 44100,
      preset: 'veryfast',
      profile: 'main',
      level: '4.1'
    };
  }

  removeStream(streamId) {
    this.stopStream(streamId);
    this.activeStreams.delete(streamId);
    this.streamProcesses.delete(streamId);
    this.streamStats.delete(streamId);
    return this.streams.delete(streamId);
  }

  updateStream(streamId, updates) {
    const stream = this.streams.get(streamId);
    if (stream) {
      Object.assign(stream, updates);
      this.streams.set(streamId, stream);
      
      // If stream is active and settings changed, restart it
      if (this.activeStreams.has(streamId) && updates.settings) {
        this.restartStream(streamId);
      }
      
      return stream;
    }
    return null;
  }

  getStreams() {
    return Array.from(this.streams.values());
  }

  getStream(streamId) {
    return this.streams.get(streamId);
  }

  async startStream(streamData) {
    let streamId;
    
    if (typeof streamData === 'string') {
      streamId = streamData;
    } else if (streamData.streamId) {
      streamId = streamData.streamId;
    } else {
      throw new Error('Invalid stream data provided');
    }

    const stream = this.streams.get(streamId);
    if (!stream) {
      throw new Error(`Stream ${streamId} not found`);
    }

    if (!stream.enabled) {
      throw new Error(`Stream ${streamId} is disabled`);
    }

    if (this.activeStreams.has(streamId)) {
      throw new Error(`Stream ${streamId} is already running`);
    }

    try {
      await this.startStreamProcess(stream);
      this.activeStreams.add(streamId);
      stream.status = 'starting';
      stream.startTime = new Date().toISOString();
      stream.retryCount = 0;
      
      console.log(`Started stream: ${stream.name}`);
      return stream;
      
    } catch (error) {
      stream.status = 'error';
      stream.lastError = error.message;
      throw error;
    }
  }

  async startStreamProcess(stream) {
    const inputUrl = process.env.COMPOSITION_INPUT || 'rtmp://localhost:1935/composed';
    const outputUrl = this.buildOutputUrl(stream);
    
    return new Promise((resolve, reject) => {
      const command = ffmpeg(inputUrl)
        .inputOptions([
          '-re',
          '-fflags', '+genpts'
        ])
        .videoCodec('libx264')
        .audioCodec('aac')
        .outputOptions([
          `-preset`, stream.settings.preset,
          `-profile:v`, stream.settings.profile,
          `-level`, stream.settings.level,
          `-b:v`, `${stream.settings.videoBitrate}k`,
          `-maxrate`, `${Math.floor(stream.settings.videoBitrate * 1.2)}k`,
          `-bufsize`, `${stream.settings.videoBitrate * 2}k`,
          `-b:a`, `${stream.settings.audioBitrate}k`,
          `-ar`, stream.settings.audioSampleRate.toString(),
          `-r`, stream.settings.framerate.toString(),
          `-g`, (stream.settings.framerate * 2).toString(),
          `-keyint_min`, stream.settings.framerate.toString(),
          `-pix_fmt`, 'yuv420p',
          `-f`, 'flv'
        ]);

      // Add resolution scaling if needed
      if (stream.settings.resolution !== '1920x1080') {
        command.size(stream.settings.resolution);
      }

      command.output(outputUrl);

      // Event handlers
      command.on('start', (commandLine) => {
        console.log(`FFmpeg started for stream ${stream.name}:`, commandLine);
        this.streamProcesses.set(stream.id, command);
        resolve(command);
      });

      command.on('progress', (progress) => {
        this.updateStreamStats(stream.id, progress);
      });

      command.on('error', (err) => {
        console.error(`Stream ${stream.name} error:`, err);
        this.handleStreamError(stream.id, err);
        reject(err);
      });

      command.on('end', () => {
        console.log(`Stream ${stream.name} ended`);
        this.handleStreamEnd(stream.id);
      });

      // Start the process
      command.run();
    });
  }

  buildOutputUrl(stream) {
    if (stream.streamKey) {
      return `${stream.url}${stream.streamKey}`;
    }
    return stream.url;
  }

  async stopStream(streamId) {
    const stream = this.streams.get(streamId);
    if (!stream) {
      throw new Error(`Stream ${streamId} not found`);
    }

    if (!this.activeStreams.has(streamId)) {
      return { message: 'Stream is not running' };
    }

    const process = this.streamProcesses.get(streamId);
    if (process) {
      try {
        process.kill('SIGTERM');
        this.streamProcesses.delete(streamId);
      } catch (error) {
        console.error(`Error stopping stream ${streamId}:`, error);
      }
    }

    this.activeStreams.delete(streamId);
    stream.status = 'stopped';
    stream.startTime = null;
    
    console.log(`Stopped stream: ${stream.name}`);
    return stream;
  }

  async stopAllStreams() {
    const stopPromises = Array.from(this.activeStreams).map(streamId => 
      this.stopStream(streamId).catch(error => 
        console.error(`Failed to stop stream ${streamId}:`, error)
      )
    );
    
    await Promise.all(stopPromises);
    console.log('All streams stopped');
  }

  async restartStream(streamId) {
    await this.stopStream(streamId);
    await new Promise(resolve => setTimeout(resolve, 1000)); // Wait 1 second
    return await this.startStream(streamId);
  }

  updateStreamStats(streamId, progress) {
    const stats = {
      fps: progress.currentFps || 0,
      bitrate: progress.currentKbps || 0,
      droppedFrames: progress.frames ? progress.frames - (progress.framesEncoded || 0) : 0,
      timemark: progress.timemark,
      timestamp: new Date().toISOString()
    };

    this.streamStats.set(streamId, stats);

    // Update stream health
    const stream = this.streams.get(streamId);
    if (stream) {
      stream.health = {
        connected: true,
        bitrate: stats.bitrate,
        droppedFrames: stats.droppedFrames,
        uptime: stream.startTime ? Date.now() - new Date(stream.startTime).getTime() : 0
      };

      // Update status to live if not already
      if (stream.status === 'starting' && stats.bitrate > 0) {
        stream.status = 'live';
      }
    }
  }

  handleStreamError(streamId, error) {
    const stream = this.streams.get(streamId);
    if (!stream) return;

    stream.status = 'error';
    stream.lastError = error.message;
    this.activeStreams.delete(streamId);
    this.streamProcesses.delete(streamId);

    // Auto-retry logic
    if (stream.retryCount < stream.maxRetries) {
      stream.retryCount++;
      console.log(`Retrying stream ${stream.name} (attempt ${stream.retryCount}/${stream.maxRetries})`);
      
      setTimeout(() => {
        this.startStream(streamId).catch(retryError => {
          console.error(`Retry failed for stream ${stream.name}:`, retryError);
        });
      }, 5000 * stream.retryCount); // Exponential backoff
    } else {
      console.error(`Stream ${stream.name} failed after ${stream.maxRetries} retries`);
    }
  }

  handleStreamEnd(streamId) {
    const stream = this.streams.get(streamId);
    if (!stream) return;

    this.activeStreams.delete(streamId);
    this.streamProcesses.delete(streamId);
    
    if (stream.status === 'live') {
      stream.status = 'stopped';
    }
  }

  startMonitoring() {
    this.monitoringInterval = setInterval(() => {
      this.checkStreamHealth();
    }, 10000); // Check every 10 seconds
  }

  checkStreamHealth() {
    for (const streamId of this.activeStreams) {
      const stream = this.streams.get(streamId);
      const stats = this.streamStats.get(streamId);
      
      if (stream && stats) {
        const lastUpdate = new Date(stats.timestamp).getTime();
        const now = Date.now();
        
        // If no stats update for 30 seconds, consider stream unhealthy
        if (now - lastUpdate > 30000) {
          console.warn(`Stream ${stream.name} appears unhealthy - no stats for ${(now - lastUpdate) / 1000}s`);
          stream.health.connected = false;
        }
      }
    }
  }

  getStatus() {
    return {
      totalStreams: this.streams.size,
      activeStreams: this.activeStreams.size,
      liveStreams: Array.from(this.streams.values()).filter(s => s.status === 'live').length,
      errorStreams: Array.from(this.streams.values()).filter(s => s.status === 'error').length
    };
  }

  getDetailedStatus() {
    const streamDetails = {};
    
    for (const [streamId, stream] of this.streams.entries()) {
      const stats = this.streamStats.get(streamId);
      streamDetails[streamId] = {
        ...stream,
        stats: stats || null,
        isActive: this.activeStreams.has(streamId)
      };
    }

    return {
      summary: this.getStatus(),
      streams: streamDetails,
      timestamp: new Date().toISOString()
    };
  }

  // Get stream URLs for external access
  getStreamUrls() {
    const urls = {};
    
    for (const [streamId, stream] of this.streams.entries()) {
      if (stream.status === 'live') {
        urls[streamId] = {
          name: stream.name,
          url: stream.url,
          type: stream.type,
          viewUrl: this.getViewUrl(stream)
        };
      }
    }

    return urls;
  }

  getViewUrl(stream) {
    // Generate view URLs for different platforms
    if (stream.url.includes('youtube.com')) {
      return 'https://studio.youtube.com/channel/UC.../livestreaming'; // User needs to fill in their channel
    } else if (stream.url.includes('facebook.com')) {
      return 'https://www.facebook.com/live/producer';
    }
    return null;
  }

  // Save stream configuration
  async saveConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/streaming.json');
      
      const config = {
        streams: Array.from(this.streams.values())
      };

      await fs.writeFile(configPath, JSON.stringify(config, null, 2));
      return true;
    } catch (error) {
      console.error('Failed to save stream config:', error);
      return false;
    }
  }

  disconnect() {
    if (this.monitoringInterval) {
      clearInterval(this.monitoringInterval);
    }
  }
}

module.exports = StreamManager;