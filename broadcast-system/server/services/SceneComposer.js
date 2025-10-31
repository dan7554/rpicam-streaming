const ffmpeg = require('fluent-ffmpeg');
const { v4: uuidv4 } = require('uuid');

class SceneComposer {
  constructor() {
    this.scenes = new Map();
    this.currentScene = null;
    this.activeComposition = null;
    this.transitionInProgress = false;
    this.outputStream = null;
    this.compositionProcess = null;
  }

  async initialize() {
    await this.loadSceneConfig();
    this.setupDefaultScenes();
  }

  async loadSceneConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/scenes.json');
      
      try {
        const configData = await fs.readFile(configPath, 'utf8');
        const config = JSON.parse(configData);
        
        for (const scene of config.scenes) {
          this.addScene(scene);
        }
      } catch (error) {
        if (error.code === 'ENOENT') {
          await this.createDefaultSceneConfig(configPath);
        } else {
          throw error;
        }
      }
    } catch (error) {
      console.error('Failed to load scene config:', error);
    }
  }

  async createDefaultSceneConfig(configPath) {
    const defaultScenes = {
      scenes: [
        {
          id: 'single-cam',
          name: 'Single Camera',
          layout: 'fullscreen',
          cameras: [
            {
              cameraId: 'rpicam',
              position: { x: 0, y: 0, width: 1920, height: 1080 },
              zIndex: 1
            }
          ],
          overlays: [],
          audio: {
            commentary: true,
            ambient: false,
            music: false
          }
        },
        {
          id: 'picture-in-picture',
          name: 'Picture in Picture',
          layout: 'pip',
          cameras: [
            {
              cameraId: 'rpicam',
              position: { x: 0, y: 0, width: 1920, height: 1080 },
              zIndex: 1
            },
            {
              cameraId: 'rpicam',
              position: { x: 1440, y: 80, width: 400, height: 225 },
              zIndex: 2
            }
          ],
          overlays: [
            {
              type: 'text',
              content: 'LIVE',
              position: { x: 50, y: 50 },
              style: { color: 'red', fontSize: '24px', fontWeight: 'bold' }
            }
          ],
          audio: {
            commentary: true,
            ambient: true,
            music: false
          }
        },
        {
          id: 'split-screen',
          name: 'Split Screen',
          layout: 'split',
          cameras: [
            {
              cameraId: 'rpicam',
              position: { x: 0, y: 0, width: 960, height: 1080 },
              zIndex: 1
            },
            {
              cameraId: 'rpicam',
              position: { x: 960, y: 0, width: 960, height: 1080 },
              zIndex: 1
            }
          ],
          overlays: [],
          audio: {
            commentary: true,
            ambient: false,
            music: false
          }
        },
        {
          id: 'quad-view',
          name: 'Quad View',
          layout: 'quad',
          cameras: [
            {
              cameraId: 'rpicam',
              position: { x: 0, y: 0, width: 960, height: 540 },
              zIndex: 1
            },
            {
              cameraId: 'rpicam',
              position: { x: 960, y: 0, width: 960, height: 540 },
              zIndex: 1
            },
            {
              cameraId: 'rpicam',
              position: { x: 0, y: 540, width: 960, height: 540 },
              zIndex: 1
            },
            {
              cameraId: 'rpicam',
              position: { x: 960, y: 540, width: 960, height: 540 },
              zIndex: 1
            }
          ],
          overlays: [
            {
              type: 'text',
              content: 'Multi-Camera View',
              position: { x: 960, y: 20 },
              style: { color: 'white', fontSize: '20px', textAlign: 'center' }
            }
          ],
          audio: {
            commentary: true,
            ambient: false,
            music: false
          }
        }
      ]
    };

    const fs = require('fs').promises;
    const path = require('path');
    
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    await fs.writeFile(configPath, JSON.stringify(defaultScenes, null, 2));
    
    for (const scene of defaultScenes.scenes) {
      this.addScene(scene);
    }
  }

  setupDefaultScenes() {
    // If no scenes loaded, set first scene as current
    if (this.scenes.size > 0 && !this.currentScene) {
      const firstScene = this.scenes.values().next().value;
      this.currentScene = firstScene;
    }
  }

  addScene(sceneConfig) {
    const scene = {
      id: sceneConfig.id || uuidv4(),
      name: sceneConfig.name,
      layout: sceneConfig.layout || 'fullscreen',
      cameras: sceneConfig.cameras || [],
      overlays: sceneConfig.overlays || [],
      audio: sceneConfig.audio || { commentary: true, ambient: false, music: false },
      transitions: sceneConfig.transitions || { type: 'cut', duration: 0 },
      created: new Date().toISOString(),
      lastUsed: null
    };

    this.scenes.set(scene.id, scene);
    return scene.id;
  }

  removeScene(sceneId) {
    if (this.currentScene && this.currentScene.id === sceneId) {
      this.currentScene = null;
    }
    return this.scenes.delete(sceneId);
  }

  updateScene(sceneId, updates) {
    const scene = this.scenes.get(sceneId);
    if (scene) {
      Object.assign(scene, updates);
      this.scenes.set(sceneId, scene);
      return scene;
    }
    return null;
  }

  getScenes() {
    return Array.from(this.scenes.values());
  }

  getScene(sceneId) {
    return this.scenes.get(sceneId);
  }

  getCurrentScene() {
    return this.currentScene;
  }

  async switchScene(sceneId, transition = { type: 'cut', duration: 0 }) {
    const newScene = this.scenes.get(sceneId);
    if (!newScene) {
      throw new Error(`Scene ${sceneId} not found`);
    }

    if (this.transitionInProgress) {
      throw new Error('Transition already in progress');
    }

    const oldScene = this.currentScene;
    this.transitionInProgress = true;

    try {
      // Apply transition
      await this.applyTransition(oldScene, newScene, transition);
      
      // Update current scene
      this.currentScene = newScene;
      newScene.lastUsed = new Date().toISOString();
      
      // Restart composition with new scene
      await this.startComposition(newScene);
      
    } catch (error) {
      console.error('Scene transition failed:', error);
      throw error;
    } finally {
      this.transitionInProgress = false;
    }

    return newScene;
  }

  async applyTransition(fromScene, toScene, transition) {
    switch (transition.type) {
      case 'cut':
        // Instant switch - no additional processing needed
        break;
        
      case 'fade':
        // Implement fade transition
        await this.applyFadeTransition(fromScene, toScene, transition.duration || 1000);
        break;
        
      case 'slide':
        // Implement slide transition
        await this.applySlideTransition(fromScene, toScene, transition.duration || 1000, transition.direction || 'left');
        break;
        
      case 'dissolve':
        // Implement dissolve transition
        await this.applyDissolveTransition(fromScene, toScene, transition.duration || 1000);
        break;
        
      default:
        console.warn(`Unknown transition type: ${transition.type}, using cut`);
    }
  }

  async applyFadeTransition(fromScene, toScene, duration) {
    // Implement fade transition using FFmpeg filters
    // This is a simplified version - in production you'd use more sophisticated compositing
    return new Promise((resolve) => {
      setTimeout(resolve, duration);
    });
  }

  async applySlideTransition(fromScene, toScene, duration, direction) {
    // Implement slide transition
    return new Promise((resolve) => {
      setTimeout(resolve, duration);
    });
  }

  async applyDissolveTransition(fromScene, toScene, duration) {
    // Implement dissolve transition
    return new Promise((resolve) => {
      setTimeout(resolve, duration);
    });
  }

  async startComposition(scene) {
    // Stop existing composition
    await this.stopComposition();

    if (!scene || scene.cameras.length === 0) {
      throw new Error('Scene has no cameras configured');
    }

    try {
      // Create FFmpeg composition based on scene layout
      this.compositionProcess = await this.createComposition(scene);
      this.activeComposition = scene;
      
      console.log(`Started composition for scene: ${scene.name}`);
      return true;
      
    } catch (error) {
      console.error('Failed to start composition:', error);
      throw error;
    }
  }

  async createComposition(scene) {
    return new Promise((resolve, reject) => {
      const outputOptions = [
        '-f', 'flv',
        '-c:v', 'libx264',
        '-preset', 'veryfast',
        '-tune', 'zerolatency',
        '-c:a', 'aac',
        '-ar', '44100',
        '-b:a', '128k',
        '-pix_fmt', 'yuv420p',
        '-g', '30',
        '-keyint_min', '30',
        '-r', '30',
        '-b:v', '3000k',
        '-maxrate', '3500k',
        '-bufsize', '6000k'
      ];

      let command = ffmpeg();

      // Add input sources based on scene cameras
      scene.cameras.forEach((camera, index) => {
        // This would be replaced with actual camera stream URLs
        const inputUrl = this.getCameraStreamUrl(camera.cameraId);
        if (inputUrl) {
          command = command.input(inputUrl);
        }
      });

      // Build filter complex for layout
      const filterComplex = this.buildFilterComplex(scene);
      
      if (filterComplex) {
        command = command.complexFilter(filterComplex);
      }

      // Set output options
      command = command.outputOptions(outputOptions);

      // Output to MediaMTX RTMP endpoint or file
      const outputUrl = process.env.COMPOSITION_OUTPUT || 'rtmp://localhost:1935/composed';
      command = command.output(outputUrl);

      // Error handling
      command.on('error', (err) => {
        console.error('FFmpeg error:', err);
        reject(err);
      });

      command.on('start', (commandLine) => {
        console.log('Started FFmpeg with command:', commandLine);
        resolve(command);
      });

      command.on('end', () => {
        console.log('Composition ended');
      });

      // Start the process
      command.run();
    });
  }

  buildFilterComplex(scene) {
    const filters = [];
    
    switch (scene.layout) {
      case 'fullscreen':
        // Single camera fullscreen
        if (scene.cameras.length > 0) {
          filters.push('[0:v]scale=1920:1080[v]');
        }
        break;
        
      case 'pip':
        // Picture in picture
        if (scene.cameras.length >= 2) {
          const mainCam = scene.cameras[0];
          const pipCam = scene.cameras[1];
          
          filters.push(
            `[0:v]scale=${mainCam.position.width}:${mainCam.position.height}[main]`,
            `[1:v]scale=${pipCam.position.width}:${pipCam.position.height}[pip]`,
            `[main][pip]overlay=${pipCam.position.x}:${pipCam.position.y}[v]`
          );
        }
        break;
        
      case 'split':
        // Split screen
        if (scene.cameras.length >= 2) {
          filters.push(
            '[0:v]scale=960:1080[left]',
            '[1:v]scale=960:1080[right]',
            '[left][right]hstack=inputs=2[v]'
          );
        }
        break;
        
      case 'quad':
        // Quad view
        if (scene.cameras.length >= 4) {
          filters.push(
            '[0:v]scale=960:540[tl]',
            '[1:v]scale=960:540[tr]',
            '[2:v]scale=960:540[bl]',
            '[3:v]scale=960:540[br]',
            '[tl][tr]hstack=inputs=2[top]',
            '[bl][br]hstack=inputs=2[bottom]',
            '[top][bottom]vstack=inputs=2[v]'
          );
        }
        break;
    }

    // Add overlays (text, graphics, etc.)
    if (scene.overlays && scene.overlays.length > 0) {
      scene.overlays.forEach((overlay, index) => {
        if (overlay.type === 'text') {
          const textFilter = `drawtext=text='${overlay.content}':x=${overlay.position.x}:y=${overlay.position.y}:fontsize=${overlay.style.fontSize || 24}:fontcolor=${overlay.style.color || 'white'}`;
          filters.push(`[v]${textFilter}[v${index + 1}]`);
          // Update reference for next overlay
          filters[filters.length - 1] = filters[filters.length - 1].replace('[v]', `[v${index}]`);
        }
      });
    }

    return filters.join(';');
  }

  getCameraStreamUrl(cameraId) {
    // This would interface with CameraManager to get the actual stream URL
    // For now, return a placeholder
    return `rtsp://localhost:8554/${cameraId}`;
  }

  async stopComposition() {
    if (this.compositionProcess) {
      try {
        this.compositionProcess.kill('SIGTERM');
        this.compositionProcess = null;
        this.activeComposition = null;
        console.log('Stopped composition process');
      } catch (error) {
        console.error('Error stopping composition:', error);
      }
    }
  }

  // Create a custom scene
  async createCustomScene(cameraPositions, overlays = [], audioSettings = {}) {
    const customScene = {
      id: uuidv4(),
      name: `Custom Scene ${new Date().toISOString()}`,
      layout: 'custom',
      cameras: cameraPositions,
      overlays: overlays,
      audio: { commentary: true, ambient: false, music: false, ...audioSettings },
      created: new Date().toISOString()
    };

    this.scenes.set(customScene.id, customScene);
    return customScene;
  }

  // Save scene configuration
  async saveConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/scenes.json');
      
      const config = {
        scenes: Array.from(this.scenes.values())
      };

      await fs.writeFile(configPath, JSON.stringify(config, null, 2));
      return true;
    } catch (error) {
      console.error('Failed to save scene config:', error);
      return false;
    }
  }

  getStatus() {
    return {
      totalScenes: this.scenes.size,
      currentScene: this.currentScene ? this.currentScene.id : null,
      activeComposition: this.activeComposition ? this.activeComposition.id : null,
      transitionInProgress: this.transitionInProgress
    };
  }

  // Get composition statistics
  getCompositionStats() {
    if (!this.activeComposition) {
      return null;
    }

    return {
      scene: this.activeComposition.name,
      cameras: this.activeComposition.cameras.length,
      overlays: this.activeComposition.overlays.length,
      uptime: this.activeComposition.startTime ? 
        Date.now() - new Date(this.activeComposition.startTime).getTime() : 0
    };
  }
}

module.exports = SceneComposer;