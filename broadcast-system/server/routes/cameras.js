const express = require('express');

module.exports = (cameraManager, io) => {
  const router = express.Router();

  // Get all cameras
  router.get('/', (req, res) => {
    try {
      const cameras = cameraManager.getCameras();
      res.json({
        success: true,
        data: cameras,
        count: cameras.length
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get specific camera
  router.get('/:id', (req, res) => {
    try {
      const camera = cameraManager.getCamera(req.params.id);
      if (!camera) {
        return res.status(404).json({
          success: false,
          error: 'Camera not found'
        });
      }
      res.json({
        success: true,
        data: camera
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Add new camera
  router.post('/', async (req, res) => {
    try {
      const { name, type, url, rtspUrl, settings, position } = req.body;

      if (!name || !url) {
        return res.status(400).json({
          success: false,
          error: 'Name and URL are required'
        });
      }

      const cameraId = cameraManager.addCamera({
        name,
        type: type || 'webrtc',
        url,
        rtspUrl,
        settings: settings || {},
        position: position || { x: 0, y: 0, width: 1920, height: 1080 },
        enabled: true
      });

      const camera = cameraManager.getCamera(cameraId);
      
      // Save configuration
      await cameraManager.saveConfig();

      // Notify clients
      io.emit('camera-added', camera);

      res.status(201).json({
        success: true,
        data: camera,
        message: 'Camera added successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Update camera
  router.put('/:id', async (req, res) => {
    try {
      const updates = req.body;
      const camera = cameraManager.updateCamera(req.params.id, updates);
      
      if (!camera) {
        return res.status(404).json({
          success: false,
          error: 'Camera not found'
        });
      }

      // Save configuration
      await cameraManager.saveConfig();

      // Notify clients
      io.emit('camera-updated', camera);

      res.json({
        success: true,
        data: camera,
        message: 'Camera updated successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Delete camera
  router.delete('/:id', async (req, res) => {
    try {
      const success = cameraManager.removeCamera(req.params.id);
      
      if (!success) {
        return res.status(404).json({
          success: false,
          error: 'Camera not found'
        });
      }

      // Save configuration
      await cameraManager.saveConfig();

      // Notify clients
      io.emit('camera-removed', { cameraId: req.params.id });

      res.json({
        success: true,
        message: 'Camera removed successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Switch to camera
  router.post('/:id/switch', async (req, res) => {
    try {
      const camera = await cameraManager.switchCamera(req.params.id);
      
      // Notify clients
      io.emit('camera-switched', { cameraId: req.params.id, camera });

      res.json({
        success: true,
        data: camera,
        message: `Switched to camera: ${camera.name}`
      });
    } catch (error) {
      res.status(400).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get camera preview URL
  router.get('/:id/preview', (req, res) => {
    try {
      const previewUrl = cameraManager.getPreviewUrl(req.params.id);
      
      if (!previewUrl) {
        return res.status(404).json({
          success: false,
          error: 'Camera not found or preview not available'
        });
      }

      res.json({
        success: true,
        data: {
          cameraId: req.params.id,
          previewUrl: previewUrl
        }
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get camera statistics
  router.get('/:id/stats', async (req, res) => {
    try {
      const stats = await cameraManager.getCameraStats(req.params.id);
      
      if (!stats) {
        return res.status(404).json({
          success: false,
          error: 'Camera not found or stats not available'
        });
      }

      res.json({
        success: true,
        data: stats
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Health check for all cameras
  router.get('/health/check', async (req, res) => {
    try {
      const healthResults = await cameraManager.checkHealth();
      
      res.json({
        success: true,
        data: healthResults,
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Test camera connection
  router.post('/:id/test', async (req, res) => {
    try {
      const isHealthy = await cameraManager.checkCameraHealth(req.params.id);
      
      res.json({
        success: true,
        data: {
          cameraId: req.params.id,
          healthy: isHealthy,
          timestamp: new Date().toISOString()
        }
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Discover new cameras from MediaMTX
  router.post('/discover', async (req, res) => {
    try {
      await cameraManager.discoverExistingStreams();
      const cameras = cameraManager.getCameras();
      
      // Notify clients
      io.emit('cameras-discovered', { cameras });

      res.json({
        success: true,
        data: cameras,
        message: 'Camera discovery completed'
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