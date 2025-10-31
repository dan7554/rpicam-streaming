const express = require('express');

module.exports = (sceneComposer, io) => {
  const router = express.Router();

  // Get all scenes
  router.get('/', (req, res) => {
    try {
      const scenes = sceneComposer.getScenes();
      const currentScene = sceneComposer.getCurrentScene();
      
      res.json({
        success: true,
        data: {
          scenes: scenes,
          currentScene: currentScene,
          count: scenes.length
        }
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get specific scene
  router.get('/:id', (req, res) => {
    try {
      const scene = sceneComposer.getScene(req.params.id);
      if (!scene) {
        return res.status(404).json({
          success: false,
          error: 'Scene not found'
        });
      }
      res.json({
        success: true,
        data: scene
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get current scene
  router.get('/current/active', (req, res) => {
    try {
      const currentScene = sceneComposer.getCurrentScene();
      res.json({
        success: true,
        data: currentScene
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Add new scene
  router.post('/', async (req, res) => {
    try {
      const { name, layout, cameras, overlays, audio, transitions } = req.body;

      if (!name) {
        return res.status(400).json({
          success: false,
          error: 'Scene name is required'
        });
      }

      const sceneId = sceneComposer.addScene({
        name,
        layout: layout || 'fullscreen',
        cameras: cameras || [],
        overlays: overlays || [],
        audio: audio || { commentary: true, ambient: false, music: false },
        transitions: transitions || { type: 'cut', duration: 0 }
      });

      const scene = sceneComposer.getScene(sceneId);
      
      // Save configuration
      await sceneComposer.saveConfig();

      // Notify clients
      io.emit('scene-added', scene);

      res.status(201).json({
        success: true,
        data: scene,
        message: 'Scene added successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Update scene
  router.put('/:id', async (req, res) => {
    try {
      const updates = req.body;
      const scene = sceneComposer.updateScene(req.params.id, updates);
      
      if (!scene) {
        return res.status(404).json({
          success: false,
          error: 'Scene not found'
        });
      }

      // Save configuration
      await sceneComposer.saveConfig();

      // Notify clients
      io.emit('scene-updated', scene);

      res.json({
        success: true,
        data: scene,
        message: 'Scene updated successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Delete scene
  router.delete('/:id', async (req, res) => {
    try {
      const success = sceneComposer.removeScene(req.params.id);
      
      if (!success) {
        return res.status(404).json({
          success: false,
          error: 'Scene not found'
        });
      }

      // Save configuration
      await sceneComposer.saveConfig();

      // Notify clients
      io.emit('scene-removed', { sceneId: req.params.id });

      res.json({
        success: true,
        message: 'Scene removed successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Switch to scene
  router.post('/:id/switch', async (req, res) => {
    try {
      const { transition } = req.body;
      
      const scene = await sceneComposer.switchScene(
        req.params.id, 
        transition || { type: 'cut', duration: 0 }
      );
      
      // Notify clients
      io.emit('scene-switched', { 
        sceneId: req.params.id, 
        scene,
        transition: transition || { type: 'cut', duration: 0 }
      });

      res.json({
        success: true,
        data: scene,
        message: `Switched to scene: ${scene.name}`
      });
    } catch (error) {
      res.status(400).json({
        success: false,
        error: error.message
      });
    }
  });

  // Start composition for scene
  router.post('/:id/compose', async (req, res) => {
    try {
      const scene = sceneComposer.getScene(req.params.id);
      if (!scene) {
        return res.status(404).json({
          success: false,
          error: 'Scene not found'
        });
      }

      await sceneComposer.startComposition(scene);
      
      // Notify clients
      io.emit('composition-started', { sceneId: req.params.id, scene });

      res.json({
        success: true,
        data: scene,
        message: `Started composition for scene: ${scene.name}`
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Stop current composition
  router.post('/compose/stop', async (req, res) => {
    try {
      await sceneComposer.stopComposition();
      
      // Notify clients
      io.emit('composition-stopped');

      res.json({
        success: true,
        message: 'Composition stopped'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Create custom scene
  router.post('/custom/create', async (req, res) => {
    try {
      const { cameraPositions, overlays, audioSettings } = req.body;

      if (!cameraPositions || cameraPositions.length === 0) {
        return res.status(400).json({
          success: false,
          error: 'Camera positions are required'
        });
      }

      const customScene = await sceneComposer.createCustomScene(
        cameraPositions,
        overlays || [],
        audioSettings || {}
      );

      // Save configuration
      await sceneComposer.saveConfig();

      // Notify clients
      io.emit('scene-added', customScene);

      res.status(201).json({
        success: true,
        data: customScene,
        message: 'Custom scene created successfully'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get composition statistics
  router.get('/compose/stats', (req, res) => {
    try {
      const stats = sceneComposer.getCompositionStats();
      
      res.json({
        success: true,
        data: stats || { message: 'No active composition' },
        timestamp: new Date().toISOString()
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Get scene layouts (available layout types)
  router.get('/layouts/available', (req, res) => {
    try {
      const layouts = [
        {
          id: 'fullscreen',
          name: 'Full Screen',
          description: 'Single camera full screen',
          maxCameras: 1,
          preview: '/assets/layouts/fullscreen.png'
        },
        {
          id: 'pip',
          name: 'Picture in Picture',
          description: 'Main camera with smaller overlay camera',
          maxCameras: 2,
          preview: '/assets/layouts/pip.png'
        },
        {
          id: 'split',
          name: 'Split Screen',
          description: 'Two cameras side by side',
          maxCameras: 2,
          preview: '/assets/layouts/split.png'
        },
        {
          id: 'quad',
          name: 'Quad View',
          description: 'Four cameras in grid layout',
          maxCameras: 4,
          preview: '/assets/layouts/quad.png'
        },
        {
          id: 'custom',
          name: 'Custom Layout',
          description: 'Custom positioning and sizing',
          maxCameras: 8,
          preview: '/assets/layouts/custom.png'
        }
      ];

      res.json({
        success: true,
        data: layouts
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Test scene transition
  router.post('/:id/test-transition', async (req, res) => {
    try {
      const { transition } = req.body;
      const scene = sceneComposer.getScene(req.params.id);
      
      if (!scene) {
        return res.status(404).json({
          success: false,
          error: 'Scene not found'
        });
      }

      // Simulate transition test
      const testResult = {
        sceneId: req.params.id,
        sceneName: scene.name,
        transition: transition || { type: 'cut', duration: 0 },
        duration: transition?.duration || 0,
        tested: true,
        timestamp: new Date().toISOString()
      };

      res.json({
        success: true,
        data: testResult,
        message: 'Transition test completed'
      });
    } catch (error) {
      res.status(500).json({
        success: false,
        error: error.message
      });
    }
  });

  // Clone scene
  router.post('/:id/clone', async (req, res) => {
    try {
      const { name } = req.body;
      const originalScene = sceneComposer.getScene(req.params.id);
      
      if (!originalScene) {
        return res.status(404).json({
          success: false,
          error: 'Scene not found'
        });
      }

      const clonedSceneConfig = {
        ...originalScene,
        name: name || `${originalScene.name} (Copy)`,
        id: undefined // Will be auto-generated
      };

      const sceneId = sceneComposer.addScene(clonedSceneConfig);
      const clonedScene = sceneComposer.getScene(sceneId);
      
      // Save configuration
      await sceneComposer.saveConfig();

      // Notify clients
      io.emit('scene-added', clonedScene);

      res.status(201).json({
        success: true,
        data: clonedScene,
        message: 'Scene cloned successfully'
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