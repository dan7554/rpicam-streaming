const ffmpeg = require('fluent-ffmpeg');
const { v4: uuidv4 } = require('uuid');

class SceneComposer {
  constructor(cameraManager) {
    this.scenes = new Map();
    this.currentScene = null;
    this.activeComposition = null;
    this.transitionInProgress = false;
    this.outputStream = null;
    this.compositionProcess = null;
    this.cameraManager = cameraManager;
    this.mediamtxHost = '192.168.50.208';
    this.mediamtxRtmpPort = '1935';
    this.mediamtxRtspPort = '8554';
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

  getSceneStreamUrl(sceneId) {
    const scene = this.scenes.get(sceneId);
    if (!scene) {
      return null;
    }

    // For multicamera scenes, return a composed stream URL
    if (scene.layout !== 'single' && scene.layout !== 'fullscreen') {
      // Return the composed scene stream URL from MediaMTX (without /whep - client will append it)
      return `https://192.168.50.208:8889/scene_${sceneId}`;
    } else {
      // For single camera scenes, return the camera's stream URL
      if (scene.cameras && scene.cameras.length > 0) {
        const camera = scene.cameras[0];
        const cameraData = this.cameraManager.getCamera(camera.cameraId || camera.id);
        if (cameraData && cameraData.url) {
          // Extract stream path from camera URL
          const urlParts = cameraData.url.split('/');
          const streamPath = urlParts[urlParts.length - 2] || urlParts[urlParts.length - 1];
          return `https://192.168.50.208:8889/${streamPath}`;
        }
      }
    }

    return null;
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
    return new Promise(async (resolve, reject) => {
      const sceneId = scene.id;
      const outputUrl = `rtmp://${this.mediamtxHost}:${this.mediamtxRtmpPort}/scene_${sceneId}`;
      
      console.log(`Creating composition for scene: ${scene.name} (${scene.layout})`);
      console.log(`RTMP output URL: ${outputUrl}`);
      
      let command = ffmpeg();
      
      // Add input sources from camera streams
      const activeCameras = [];
      scene.cameras.forEach((camera, index) => {
        const cameraData = this.cameraManager.getCamera(camera.cameraId || camera.id);
        console.log(`Processing camera ${index}:`, {
          sceneCamera: camera,
          cameraData: cameraData ? {
            id: cameraData.id,
            url: cameraData.url,
            rtspUrl: cameraData.rtspUrl,
            status: cameraData.status
          } : null
        });
        
        if (cameraData && cameraData.status === 'online') {
          // Extract the actual stream path from the camera's URL
          let streamPath;
          if (cameraData.rtspUrl) {
            // Extract path from rtspUrl (e.g., "rtsp://host:8554/rpicam1" -> "rpicam1")
            streamPath = cameraData.rtspUrl.split('/').pop();
          } else if (cameraData.url) {
            // Extract path from webrtc url (e.g., "https://host:8889/rpicam1/" -> "rpicam1")
            const urlParts = cameraData.url.split('/');
            streamPath = urlParts[urlParts.length - 2] || urlParts[urlParts.length - 1];
          } else {
            console.warn(`No valid stream URL found for camera ${cameraData.id}`);
            return;
          }
          
          const inputUrl = `rtsp://${this.mediamtxHost}:${this.mediamtxRtspPort}/${streamPath}`;
          
          // Add RTSP input with TCP transport to avoid "Unsupported Transport" error
          command = command.input(inputUrl)
            .inputOptions([
              '-rtsp_transport', 'tcp',
              '-rtsp_flags', 'prefer_tcp',
              '-fflags', '+genpts+discardcorrupt',
              '-timeout', '3000000',   // 3 second timeout in microseconds
              '-max_delay', '100000',  // 0.1 second max delay
              '-analyzeduration', '1000000',  // 1 second analyze
              '-probesize', '32768'    // Small probe size for faster startup
            ]);
          
          activeCameras.push({ ...camera, index, cameraData });
          console.log(`Added input ${index}: ${inputUrl} (stream path: ${streamPath}) with TCP transport`);
        }
      });

      if (activeCameras.length === 0) {
        reject(new Error('No active cameras available for composition'));
        return;
      }

      console.log(`Found ${activeCameras.length} active cameras for scene composition`);

      // Test connectivity to MediaMTX RTSP port before starting composition
      console.log(`Testing MediaMTX RTSP connectivity at ${this.mediamtxHost}:${this.mediamtxRtspPort}`);

      // Build filter complex based on layout
      const filterComplex = this.buildFilterComplex(scene, activeCameras);
      
      console.log(`Filter complex result:`, filterComplex);
      
      if (filterComplex && filterComplex.length > 0) {
        console.log(`Using complex filter with ${filterComplex.length} filters`);
        command = command.complexFilter(filterComplex);
        command = command.map('[v]').map('[a]');
      } else {
        console.log(`Using simple mapping for single camera`);
        // Single input, no complex filter needed - but we need to add silent audio
        command = command.map('0:v');
        // Add silent audio track since cameras likely don't have audio
        command = command.complexFilter(['anullsrc=channel_layout=stereo:sample_rate=44100[silent_audio]']);
        command = command.map('[silent_audio]');
      }

      // Output options for streaming to MediaMTX via RTMP
      command = command.outputOptions([
        '-f', 'flv',
        '-c:v', 'libx264',
        '-preset', 'superfast',
        '-tune', 'zerolatency',
        '-profile:v', 'baseline',
        '-level', '3.0',
        '-pix_fmt', 'yuv420p',
        '-r', '15',
        '-g', '15',
        '-keyint_min', '15',
        '-sc_threshold', '0',
        '-b:v', '800k',
        '-maxrate', '1000k',
        '-bufsize', '800k',
        '-c:a', 'aac',
        '-b:a', '64k',
        '-ar', '22050',
        '-ac', '1',
        '-shortest',
        '-avoid_negative_ts', 'make_zero',
        '-fflags', '+genpts+flush_packets',
        '-flush_packets', '1',
        '-muxdelay', '0',
        '-muxpreload', '0'
      ]);

      command = command.output(outputUrl);

      // Error handling with specific transport error detection
      command.on('error', (err) => {
        console.error(`FFmpeg error for scene ${sceneId}:`, err);
        
        // Check for transport-related errors
        if (err.message.includes('Unsupported Transport') || 
            err.message.includes('method SETUP failed')) {
          console.error(`Transport error detected. Ensure MediaMTX supports TCP and cameras are accessible.`);
          console.error(`This might be caused by: 1) Cameras not streaming, 2) Network issues, 3) MediaMTX configuration`);
        }
        
        reject(err);
      });

      command.on('start', (commandLine) => {
        console.log(`Started FFmpeg composition for scene ${sceneId}:`);
        console.log(commandLine);
        resolve(command);
      });

      command.on('end', () => {
        console.log(`Composition ended for scene ${sceneId}`);
      });

      command.on('stderr', (stderrLine) => {
        console.log(`FFmpeg [${sceneId}]: ${stderrLine}`);
      });

      // Start the composition
      command.run();
    });
  }

  buildFilterComplex(scene, activeCameras) {
    const filters = [];
    
    console.log(`Building filter complex for scene layout: ${scene.layout}, active cameras: ${activeCameras.length}`);
    
    switch (scene.layout) {
      case 'single':
      case 'fullscreen':
        // Single camera fullscreen - no complex filter needed
        return null;
        
      case 'multi-cam':
        // Multi-camera layout - default to quad view if 4+ cameras, otherwise side-by-side
        console.log(`Multi-cam layout with ${activeCameras.length} cameras`);
        if (activeCameras.length >= 4) {
          console.log(`Creating quad layout for 4+ cameras`);
          const videoFilters = [
            '[0:v]scale=960:540[top_left]',
            '[1:v]scale=960:540[top_right]',
            '[2:v]scale=960:540[bottom_left]',
            '[3:v]scale=960:540[bottom_right]',
            '[top_left][top_right]hstack[top]',
            '[bottom_left][bottom_right]hstack[bottom]',
            '[top][bottom]vstack[v]'
          ];
          
          filters.push(...videoFilters);
          
          // Only add audio mixing if we have audio streams (most Pi cameras are video-only)
          // We'll generate a silent audio track instead
          filters.push('anullsrc=channel_layout=stereo:sample_rate=44100[a]');
          
          console.log(`Generated ${filters.length} filters:`, filters);
          return filters;
        } else if (activeCameras.length >= 2) {
          console.log(`Creating side-by-side layout for 2-3 cameras`);
          const videoFilters = [
            '[0:v]scale=960:1080[left]',
            '[1:v]scale=960:1080[right]',
            '[left][right]hstack[v]'
          ];
          
          filters.push(...videoFilters);
          
          // Generate silent audio track
          filters.push('anullsrc=channel_layout=stereo:sample_rate=44100[a]');
          
          console.log(`Generated ${filters.length} filters:`, filters);
          return filters;
        } else {
          console.log(`Single camera - no complex filter needed`);
          return null;
        }
        break;
        
      case 'side-by-side':
        // Side by side layout
        if (activeCameras.length >= 2) {
          filters.push(
            '[0:v]scale=960:1080[left]',
            '[1:v]scale=960:1080[right]',
            '[left][right]hstack=inputs=2[v]'
          );
          // Generate silent audio track
          filters.push('anullsrc=channel_layout=stereo:sample_rate=44100[a]');
          return filters;
        }
        break;
        
      case 'quad':
        // Quad split layout
        if (activeCameras.length >= 4) {
          filters.push(
            '[0:v]scale=960:540[top_left]',
            '[1:v]scale=960:540[top_right]',
            '[2:v]scale=960:540[bottom_left]',
            '[3:v]scale=960:540[bottom_right]',
            '[top_left][top_right]hstack[top]',
            '[bottom_left][bottom_right]hstack[bottom]',
            '[top][bottom]vstack[v]'
          );
          // Generate silent audio track
          filters.push('anullsrc=channel_layout=stereo:sample_rate=44100[a]');
          return filters;
        } else if (activeCameras.length >= 2) {
          // Fall back to side-by-side for 2 cameras
          filters.push(
            '[0:v]scale=960:540[left]',
            '[1:v]scale=960:540[right]',
            '[left][right]hstack=inputs=2[v]'
          );
          filters.push('anullsrc=channel_layout=stereo:sample_rate=44100[a]');
          return filters;
        }
        break;
        
      case 'picture-in-picture':
        // Picture in picture
        if (activeCameras.length >= 2) {
          filters.push(
            '[0:v]scale=1920:1080[main]',
            '[1:v]scale=384:216[pip]',
            '[main][pip]overlay=W-w-20:20[v]'
          );
          // Generate silent audio track
          filters.push('anullsrc=channel_layout=stereo:sample_rate=44100[a]');
          return filters;
        }
        break;
        
      case 'triple':
        // Triple layout - one large, two small
        if (activeCameras.length >= 3) {
          filters.push(
            '[0:v]scale=1280:1080[main]',
            '[1:v]scale=640:360[small1]',
            '[2:v]scale=640:360[small2]',
            '[small1][small2]vstack[side]',
            '[main][side]hstack[v]'
          );
          filters.push('anullsrc=channel_layout=stereo:sample_rate=44100[a]');
          return filters;
        }
        break;
        
      default:
        // Single camera fallback
        return null;
    }
    
    // Single camera fallback
    return null;
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