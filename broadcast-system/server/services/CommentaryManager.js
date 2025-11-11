const { v4: uuidv4 } = require('uuid');

class CommentaryManager {
  constructor() {
    this.commentators = new Map();
    this.activeCommentators = new Set();
    this.audioMixer = null;
    this.recordingSessions = new Map();
    this.pushToTalkStates = new Map();
    this.audioLevels = new Map();
    this.mixerSettings = {
      masterVolume: 1.0,
      commentaryVolume: 1.0,
      ambientVolume: 0.3,
      musicVolume: 0.2,
      compressionEnabled: true,
      noiseGateEnabled: true,
      echoCancellation: true
    };
  }

  async initialize() {
    await this.loadCommentaryConfig();
    this.setupAudioMixer();
    this.startAudioLevelMonitoring();
  }

  async loadCommentaryConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/commentary.json');
      
      try {
        const configData = await fs.readFile(configPath, 'utf8');
        const config = JSON.parse(configData);
        
        for (const commentator of config.commentators) {
          this.addCommentator(commentator);
        }
        
        if (config.mixerSettings) {
          this.mixerSettings = { ...this.mixerSettings, ...config.mixerSettings };
        }
      } catch (error) {
        if (error.code === 'ENOENT') {
          await this.createDefaultCommentaryConfig(configPath);
        } else {
          throw error;
        }
      }
    } catch (error) {
      console.error('Failed to load commentary config:', error);
    }
  }

  async createDefaultCommentaryConfig(configPath) {
    const defaultConfig = {
      commentators: [
        {
          id: 'main-commentator',
          name: 'Main Commentator',
          enabled: true,
          inputDevice: 'default',
          settings: {
            gain: 1.0,
            noiseGate: true,
            compression: true,
            pushToTalk: false,
            pushToTalkKey: 'F1',
            autoGainControl: true,
            echoCancellation: true
          },
          position: 'center'
        },
        {
          id: 'color-commentator',
          name: 'Color Commentator',
          enabled: false,
          inputDevice: 'default',
          settings: {
            gain: 0.8,
            noiseGate: true,
            compression: true,
            pushToTalk: true,
            pushToTalkKey: 'F2',
            autoGainControl: true,
            echoCancellation: true
          },
          position: 'left'
        },
        {
          id: 'field-reporter',
          name: 'Field Reporter',
          enabled: false,
          inputDevice: 'default',
          settings: {
            gain: 0.9,
            noiseGate: true,
            compression: true,
            pushToTalk: true,
            pushToTalkKey: 'F3',
            autoGainControl: true,
            echoCancellation: true
          },
          position: 'right'
        }
      ],
      mixerSettings: this.mixerSettings,
      audioSources: [
        {
          id: 'ambient-track',
          name: 'Ambient Track',
          type: 'file',
          source: './audio/ambient.mp3',
          enabled: false,
          loop: true,
          volume: 0.3
        },
        {
          id: 'intro-music',
          name: 'Intro Music',
          type: 'file',
          source: './audio/intro.mp3',
          enabled: false,
          loop: false,
          volume: 0.5
        },
        {
          id: 'race-audio',
          name: 'Race Track Audio',
          type: 'line-in',
          source: 'default',
          enabled: true,
          volume: 0.4
        }
      ]
    };

    const fs = require('fs').promises;
    const path = require('path');
    
    await fs.mkdir(path.dirname(configPath), { recursive: true });
    await fs.writeFile(configPath, JSON.stringify(defaultConfig, null, 2));
    
    for (const commentator of defaultConfig.commentators) {
      this.addCommentator(commentator);
    }
  }

  addCommentator(commentatorConfig) {
    const commentator = {
      id: commentatorConfig.id || uuidv4(),
      name: commentatorConfig.name,
      enabled: commentatorConfig.enabled !== false,
      inputDevice: commentatorConfig.inputDevice || 'default',
      settings: {
        gain: 1.0,
        noiseGate: true,
        compression: true,
        pushToTalk: false,
        pushToTalkKey: 'F1',
        autoGainControl: true,
        echoCancellation: true,
        ...commentatorConfig.settings
      },
      position: commentatorConfig.position || 'center',
      status: 'disconnected',
      audioStream: null,
      recordingStream: null,
      isRecording: false,
      isMuted: false,
      currentLevel: 0,
      peakLevel: 0,
      connected: false
    };

    this.commentators.set(commentator.id, commentator);
    this.pushToTalkStates.set(commentator.id, false);
    this.audioLevels.set(commentator.id, { level: 0, peak: 0, timestamp: Date.now() });
    
    return commentator.id;
  }

  removeCommentator(commentatorId) {
    this.stopCommentary(commentatorId);
    this.activeCommentators.delete(commentatorId);
    this.pushToTalkStates.delete(commentatorId);
    this.audioLevels.delete(commentatorId);
    return this.commentators.delete(commentatorId);
  }

  updateCommentator(commentatorId, updates) {
    const commentator = this.commentators.get(commentatorId);
    if (commentator) {
      Object.assign(commentator, updates);
      this.commentators.set(commentatorId, commentator);
      
      // Apply real-time settings if commentator is active
      if (this.activeCommentators.has(commentatorId)) {
        this.applyAudioSettings(commentator);
      }
      
      return commentator;
    }
    return null;
  }

  getCommentators() {
    return Array.from(this.commentators.values());
  }

  getCommentator(commentatorId) {
    return this.commentators.get(commentatorId);
  }

  async startCommentary(commentatorId) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator) {
      throw new Error(`Commentator ${commentatorId} not found`);
    }

    if (!commentator.enabled) {
      throw new Error(`Commentator ${commentatorId} is disabled`);
    }

    if (this.activeCommentators.has(commentatorId)) {
      return { message: 'Commentary already active', commentator };
    }

    try {
      // Initialize WebRTC audio input for this commentator
      await this.initializeAudioInput(commentator);
      
      this.activeCommentators.add(commentatorId);
      commentator.status = 'active';
      commentator.connected = true;
      
      console.log(`Started commentary for: ${commentator.name}`);
      return commentator;
      
    } catch (error) {
      commentator.status = 'error';
      commentator.connected = false;
      throw error;
    }
  }

  async initializeAudioInput(commentator) {
    // This would be implemented with WebRTC or WebAudio API on the client side
    // For the server side, we simulate the audio stream setup
    
    commentator.audioStream = {
      id: uuidv4(),
      sampleRate: 44100,
      channels: 1,
      format: 'float32',
      connected: true,
      startTime: new Date().toISOString()
    };

    // Apply audio processing settings
    this.applyAudioSettings(commentator);
    
    // Start recording if enabled
    if (commentator.settings.enableRecording) {
      await this.startRecording(commentator.id);
    }
  }

  applyAudioSettings(commentator) {
    // Apply audio processing settings
    const settings = commentator.settings;
    
    // This would apply real-time audio processing:
    // - Gain control
    // - Noise gate
    // - Compression
    // - Echo cancellation
    // - Auto gain control
    
    console.log(`Applied audio settings for ${commentator.name}:`, settings);
  }

  async stopCommentary(commentatorId) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator) {
      throw new Error(`Commentator ${commentatorId} not found`);
    }

    if (!this.activeCommentators.has(commentatorId)) {
      return { message: 'Commentary not active', commentator };
    }

    try {
      // Stop recording if active
      if (commentator.isRecording) {
        await this.stopRecording(commentatorId);
      }

      // Close audio stream
      if (commentator.audioStream) {
        commentator.audioStream.connected = false;
        commentator.audioStream = null;
      }

      this.activeCommentators.delete(commentatorId);
      commentator.status = 'disconnected';
      commentator.connected = false;
      commentator.currentLevel = 0;
      commentator.peakLevel = 0;
      
      console.log(`Stopped commentary for: ${commentator.name}`);
      return commentator;
      
    } catch (error) {
      commentator.status = 'error';
      throw error;
    }
  }

  async stopAllCommentary() {
    const stopPromises = Array.from(this.activeCommentators).map(commentatorId => 
      this.stopCommentary(commentatorId).catch(error => 
        console.error(`Failed to stop commentary ${commentatorId}:`, error)
      )
    );
    
    await Promise.all(stopPromises);
    console.log('All commentary stopped');
  }

  // Push-to-talk functionality
  setPushToTalk(commentatorId, isPressed) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator || !commentator.settings.pushToTalk) {
      return false;
    }

    const wasPressed = this.pushToTalkStates.get(commentatorId);
    this.pushToTalkStates.set(commentatorId, isPressed);

    if (isPressed !== wasPressed) {
      commentator.isMuted = !isPressed;
      console.log(`Push-to-talk ${isPressed ? 'pressed' : 'released'} for ${commentator.name}`);
      return true;
    }
    
    return false;
  }

  // Mute/unmute functionality
  toggleMute(commentatorId) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator) return false;

    commentator.isMuted = !commentator.isMuted;
    console.log(`${commentator.isMuted ? 'Muted' : 'Unmuted'} ${commentator.name}`);
    return commentator.isMuted;
  }

  setMute(commentatorId, isMuted) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator) return false;

    commentator.isMuted = isMuted;
    return true;
  }

  // Recording functionality
  async startRecording(commentatorId) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator || !this.activeCommentators.has(commentatorId)) {
      throw new Error('Commentator not active');
    }

    if (commentator.isRecording) {
      return { message: 'Already recording' };
    }

    const recordingSession = {
      id: uuidv4(),
      commentatorId: commentatorId,
      startTime: new Date().toISOString(),
      filename: `commentary_${commentatorId}_${Date.now()}.wav`,
      format: 'wav',
      sampleRate: 44100,
      channels: 1
    };

    this.recordingSessions.set(recordingSession.id, recordingSession);
    commentator.recordingStream = recordingSession;
    commentator.isRecording = true;

    console.log(`Started recording for ${commentator.name}: ${recordingSession.filename}`);
    return recordingSession;
  }

  async stopRecording(commentatorId) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator || !commentator.isRecording) {
      return { message: 'Not recording' };
    }

    const recordingSession = commentator.recordingStream;
    if (recordingSession) {
      recordingSession.endTime = new Date().toISOString();
      recordingSession.duration = Date.now() - new Date(recordingSession.startTime).getTime();
      
      commentator.recordingStream = null;
      commentator.isRecording = false;

      console.log(`Stopped recording for ${commentator.name}: ${recordingSession.filename}`);
      return recordingSession;
    }

    return null;
  }

  // Audio mixer setup
  setupAudioMixer() {
    this.audioMixer = {
      inputs: new Map(),
      outputs: new Map(),
      effects: {
        masterCompressor: { enabled: this.mixerSettings.compressionEnabled },
        noiseGate: { enabled: this.mixerSettings.noiseGateEnabled },
        echoCancellation: { enabled: this.mixerSettings.echoCancellation }
      },
      settings: this.mixerSettings
    };

    console.log('Audio mixer initialized');
  }

  updateMixerSettings(newSettings) {
    this.mixerSettings = { ...this.mixerSettings, ...newSettings };
    
    if (this.audioMixer) {
      this.audioMixer.settings = this.mixerSettings;
      
      // Apply new settings to active commentators
      for (const commentatorId of this.activeCommentators) {
        const commentator = this.commentators.get(commentatorId);
        if (commentator) {
          this.applyAudioSettings(commentator);
        }
      }
    }

    return this.mixerSettings;
  }

  // Audio level monitoring
  startAudioLevelMonitoring() {
    setInterval(() => {
      for (const commentatorId of this.activeCommentators) {
        this.updateAudioLevels(commentatorId);
      }
    }, 100); // Update every 100ms for smooth level meters
  }

  updateAudioLevels(commentatorId) {
    const commentator = this.commentators.get(commentatorId);
    if (!commentator || !commentator.audioStream) return;

    // Simulate audio level detection
    // In a real implementation, this would analyze the actual audio stream
    const baseLevel = commentator.isMuted ? 0 : Math.random() * 0.8 + 0.1;
    const currentLevel = baseLevel * commentator.settings.gain;
    const peakLevel = Math.max(currentLevel, commentator.peakLevel * 0.95);

    commentator.currentLevel = currentLevel;
    commentator.peakLevel = peakLevel;

    this.audioLevels.set(commentatorId, {
      level: currentLevel,
      peak: peakLevel,
      timestamp: Date.now(),
      clipping: peakLevel > 0.95
    });
  }

  getAudioLevels() {
    const levels = {};
    for (const [commentatorId, levelData] of this.audioLevels.entries()) {
      levels[commentatorId] = levelData;
    }
    return levels;
  }

  // Commentary presets
  createPreset(name, commentatorSettings) {
    const preset = {
      id: uuidv4(),
      name: name,
      settings: commentatorSettings,
      created: new Date().toISOString()
    };

    // Save preset to config
    // Implementation would save to file system
    
    return preset;
  }

  applyPreset(presetId) {
    // Implementation would load and apply preset settings
    console.log(`Applied preset: ${presetId}`);
  }

  getStatus() {
    return {
      totalCommentators: this.commentators.size,
      activeCommentators: this.activeCommentators.size,
      recordingSessions: this.recordingSessions.size,
      mixerEnabled: !!this.audioMixer,
      mixerSettings: this.mixerSettings
    };
  }

  getDetailedStatus() {
    const commentatorDetails = {};
    
    for (const [commentatorId, commentator] of this.commentators.entries()) {
      const levels = this.audioLevels.get(commentatorId);
      commentatorDetails[commentatorId] = {
        ...commentator,
        levels: levels || null,
        isActive: this.activeCommentators.has(commentatorId),
        pushToTalkActive: this.pushToTalkStates.get(commentatorId) || false
      };
    }

    return {
      summary: this.getStatus(),
      commentators: commentatorDetails,
      audioLevels: this.getAudioLevels(),
      timestamp: new Date().toISOString()
    };
  }

  getStats() {
    return this.getDetailedStatus();
  }

  // Save commentary configuration
  async saveConfig() {
    try {
      const fs = require('fs').promises;
      const configPath = require('path').join(__dirname, '../../config/commentary.json');
      
      const config = {
        commentators: Array.from(this.commentators.values()),
        mixerSettings: this.mixerSettings
      };

      await fs.writeFile(configPath, JSON.stringify(config, null, 2));
      return true;
    } catch (error) {
      console.error('Failed to save commentary config:', error);
      return false;
    }
  }
}

module.exports = CommentaryManager;