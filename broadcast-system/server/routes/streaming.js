const express = require('express');

module.exports = (streamManager, io) => {
  const router = express.Router();

  // Get all streams
  router.get('/', (req, res) => {
    try {
      const streams = streamManager.getStreams();
      res.json({
        success: true,
        data: streams,
        count: streams.length
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get specific stream
  router.get('/:id', (req, res) => {
    try {
      const stream = streamManager.getStream(req.params.id);
      if (!stream) {
        return res.status(404).json({
          success: false,
          error: 'Stream not found'
        });
      }
      res.json({
        success: true,
        data: stream
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get stream status
  router.get('/status/all', (req, res) => {
    try {
      const status = streamManager.getDetailedStatus();
      res.json({
        success: true,
        data: status
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get stream URLs for viewing
  router.get('/urls/view', (req, res) => {
    try {
      const urls = streamManager.getStreamUrls();
      res.json({
        success: true,
        data: urls
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Add new stream
  router.post('/', async (req, res) => {
    try {
      const { name, type, url, streamKey, settings } = req.body;

      if (!name || !url) {
        return res.status(400).json({
          success: false,
          error: 'Name and URL are required'
        });
      }

      const streamId = streamManager.addStream({
        name,
        type: type || 'rtmp',
        url,
        streamKey: streamKey || '',
        settings: settings || streamManager.getDefaultSettings(),
        enabled: true
      });

      const stream = streamManager.getStream(streamId);
      
      // Save configuration
      await streamManager.saveConfig();

      // Notify clients
      io.emit('stream-added', stream);

      res.status(201).json({
        success: true,
        data: stream,
        message: 'Stream added successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Update stream
  router.put('/:id', async (req, res) => {
    try {
      const updates = req.body;
      const stream = streamManager.updateStream(req.params.id, updates);
      
      if (!stream) {
        return res.status(404).json({
          success: false,
          error: 'Stream not found'
        });
      }

      // Save configuration
      await streamManager.saveConfig();

      // Notify clients
      io.emit('stream-updated', stream);

      res.json({
        success: true,
        data: stream,
        message: 'Stream updated successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Delete stream
  router.delete('/:id', async (req, res) => {
    try {
      const success = streamManager.removeStream(req.params.id);
      
      if (!success) {
        return res.status(404).json({
          success: false,
          error: 'Stream not found'
        });
      }

      // Save configuration
      await streamManager.saveConfig();

      // Notify clients
      io.emit('stream-removed', { streamId: req.params.id });

      res.json({
        success: true,
        message: 'Stream removed successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Start stream
  router.post('/:id/start', async (req, res) => {
    try {
      const stream = await streamManager.startStream(req.params.id);
      
      // Notify clients
      io.emit('stream-started', { streamId: req.params.id, stream });

      res.json({
        success: true,
        data: stream,
        message: `Started stream: ${stream.name}`
      });
    } catch (error) {
      res.status(400).json({
        success: false,
        error: error.message
      });
    }
  });

  // Stop stream
  router.post('/:id/stop', async (req, res) => {
    try {
      const stream = await streamManager.stopStream(req.params.id);
      
      // Notify clients
      io.emit('stream-stopped', { streamId: req.params.id, stream });

      res.json({
        success: true,
        data: stream,
        message: `Stopped stream: ${stream.name}`
      });
    } catch (error) {
      res.status(400).json({
        success: false,
        error: error.message
      });
    }
  });

  // Restart stream
  router.post('/:id/restart', async (req, res) => {
    try {
      const stream = await streamManager.restartStream(req.params.id);
      
      // Notify clients
      io.emit('stream-restarted', { streamId: req.params.id, stream });

      res.json({
        success: true,
        data: stream,
        message: `Restarted stream: ${stream.name}`
      });
    } catch (error) {
      res.status(400).json({
        success: false,
        error: error.message
      });
    }
  });

  // Start all enabled streams
  router.post('/start-all', async (req, res) => {
    try {
      const streams = streamManager.getStreams().filter(s => s.enabled);
      const results = [];

      for (const stream of streams) {
        try {
          const startedStream = await streamManager.startStream(stream.id);
          results.push({ streamId: stream.id, success: true, stream: startedStream });
        } catch (error) {
          results.push({ streamId: stream.id, success: false, error: error.message });
        }
      }

      // Notify clients
      io.emit('streams-batch-started', { results });

      const successCount = results.filter(r => r.success).length;
      const failCount = results.length - successCount;

      res.json({
        success: true,
        data: results,
        message: `Started ${successCount} streams${failCount > 0 ? `, ${failCount} failed` : ''}`
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Stop all streams
  router.post('/stop-all', async (req, res) => {
    try {
      await streamManager.stopAllStreams();
      
      // Notify clients
      io.emit('streams-all-stopped');

      res.json({
        success: true,
        message: 'All streams stopped'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Test stream connection
  router.post('/:id/test', async (req, res) => {
    try {
      const stream = streamManager.getStream(req.params.id);
      if (!stream) {
        return res.status(404).json({
          success: false,
          error: 'Stream not found'
        });
      }

      // Test connection (simplified - in production would do actual RTMP handshake test)
      const testResult = {
        streamId: req.params.id,
        streamName: stream.name,
        url: stream.url,
        reachable: true, // Would be actual test result
        latency: Math.floor(Math.random() * 100) + 50, // Simulated latency
        timestamp: new Date().toISOString()
      };

      res.json({
        success: true,
        data: testResult
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get stream presets
  router.get('/presets/available', (req, res) => {
    try {
      const presets = [
        {
          id: 'youtube-1080p',
          name: 'YouTube 1080p',
          description: 'Optimized for YouTube Live 1080p streaming',
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
          id: 'youtube-720p',
          name: 'YouTube 720p',
          description: 'Optimized for YouTube Live 720p streaming',
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
          description: 'Optimized for Facebook Live streaming',
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
          id: 'low-bandwidth',
          name: 'Low Bandwidth',
          description: 'For slow internet connections',
          settings: {
            resolution: '854x480',
            framerate: 24,
            videoBitrate: 1200,
            audioBitrate: 96,
            audioSampleRate: 44100,
            preset: 'medium',
            profile: 'baseline',
            level: '3.0'
          }
        },
        {
          id: 'high-quality',
          name: 'High Quality',
          description: 'Maximum quality for fast connections',
          settings: {
            resolution: '1920x1080',
            framerate: 60,
            videoBitrate: 8000,
            audioBitrate: 256,
            audioSampleRate: 48000,
            preset: 'medium',
            profile: 'high',
            level: '4.2'
          }
        }
      ];

      res.json({
        success: true,
        data: presets
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Apply preset to stream
  router.post('/:id/preset/:presetId', async (req, res) => {
    try {
      const stream = streamManager.getStream(req.params.id);
      if (!stream) {
        return res.status(404).json({
          success: false,
          error: 'Stream not found'
        });
      }

      // Get preset settings (would normally be loaded from config)
      const presets = {
        'youtube-1080p': {
          resolution: '1920x1080',
          framerate: 30,
          videoBitrate: 6000,
          audioBitrate: 128,
          audioSampleRate: 44100,
          preset: 'veryfast',
          profile: 'main',
          level: '4.1'
        },
        'youtube-720p': {
          resolution: '1280x720',
          framerate: 30,
          videoBitrate: 3000,
          audioBitrate: 128,
          audioSampleRate: 44100,
          preset: 'fast',
          profile: 'main',
          level: '3.1'
        }
        // Add other presets...
      };

      const presetSettings = presets[req.params.presetId];
      if (!presetSettings) {
        return res.status(404).json({
          success: false,
          error: 'Preset not found'
        });
      }

      // Update stream with preset settings
      const updatedStream = streamManager.updateStream(req.params.id, {
        settings: presetSettings
      });

      // Save configuration
      await streamManager.saveConfig();

      // Notify clients
      io.emit('stream-preset-applied', { 
        streamId: req.params.id, 
        presetId: req.params.presetId,
        stream: updatedStream 
      });

      res.json({
        success: true,
        data: updatedStream,
        message: `Applied preset ${req.params.presetId} to stream ${stream.name}`
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get YouTube setup instructions
  router.get('/youtube/setup', (req, res) => {
    try {
      const instructions = {
        steps: [
          {
            step: 1,
            title: 'Enable Live Streaming',
            description: 'Go to YouTube Studio and enable live streaming for your channel',
            url: 'https://studio.youtube.com/'
          },
          {
            step: 2,
            title: 'Create Live Stream',
            description: 'Click "Go Live" and select "Stream" option',
            details: 'Choose "Stream" instead of webcam for RTMP streaming'
          },
          {
            step: 3,
            title: 'Get Stream Key',
            description: 'Copy your stream key from the YouTube Live dashboard',
            warning: 'Keep your stream key private - anyone with it can stream to your channel'
          },
          {
            step: 4,
            title: 'Configure Stream Settings',
            description: 'Set your stream title, description, and privacy settings',
            tips: [
              'Use descriptive titles for better discoverability',
              'Add relevant tags and category',
              'Set appropriate audience settings'
            ]
          },
          {
            step: 5,
            title: 'Add Stream to Broadcast System',
            description: 'Create a new stream in the broadcast system with your YouTube details',
            settings: {
              name: 'YouTube Live Main',
              type: 'rtmp',
              url: 'rtmp://a.rtmp.youtube.com/live2/',
              streamKey: 'YOUR_STREAM_KEY_HERE'
            }
          }
        ],
        rtmpUrls: [
          {
            location: 'Primary',
            url: 'rtmp://a.rtmp.youtube.com/live2/',
            description: 'Main YouTube RTMP server'
          },
          {
            location: 'Backup',
            url: 'rtmp://b.rtmp.youtube.com/live2/',
            description: 'Backup YouTube RTMP server'
          }
        ],
        requirements: {
          minimumBitrate: 1000,
          maximumBitrate: 9000,
          recommendedBitrate: 6000,
          supportedFormats: ['H.264', 'AAC'],
          maxDuration: 'No limit for verified channels'
        }
      };

      res.json({
        success: true,
        data: instructions
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  return router;
};