import { create } from 'zustand';
import { devtools } from 'zustand/middleware';

export const useBroadcastStore = create(
  devtools(
    (set, get) => ({
      // Connection state
      connected: false,
      connectionError: null,

      // System state
      systemStatus: {
        cameras: { total: 0, online: 0, offline: 0 },
        streams: { active: 0, viewers: 0 },
        system: { cpu: 0, memory: 0, uptime: 0 }
      },

      // Cameras
      cameras: [],
      activeCamera: null,

      // Scenes
      scenes: [],
      activeScene: null,

      // Streams
      streams: [],
      activeStreams: [],

      // Commentary
      commentaryEnabled: false,
      audioLevel: 0,

      // Actions
      setConnectionStatus: (status) =>
        set({ connected: status }, false, 'setConnectionStatus'),

      setConnectionError: (error) =>
        set({ connectionError: error }, false, 'setConnectionError'),

      updateSystemStatus: (status) =>
        set({ systemStatus: status && typeof status === 'object' ? status : {} }, false, 'updateSystemStatus'),

      setCameras: (cameras) =>
        set({ cameras: Array.isArray(cameras) ? cameras : [] }, false, 'setCameras'),

      setActiveCamera: (cameraId) =>
        set({ activeCamera: cameraId }, false, 'setActiveCamera'),

      updateCamera: (cameraId, updates) =>
        set((state) => ({
          cameras: Array.isArray(state.cameras) ? state.cameras.map(camera =>
            camera?.id === cameraId ? { ...camera, ...updates } : camera
          ) : []
        }), false, 'updateCamera'),

      addCamera: (camera) =>
        set((state) => ({
          cameras: camera ? [...(Array.isArray(state.cameras) ? state.cameras : []), camera] : state.cameras
        }), false, 'addCamera'),

      removeCamera: (cameraId) =>
        set((state) => ({
          cameras: Array.isArray(state.cameras) ? state.cameras.filter(camera => camera?.id !== cameraId) : [],
          activeCamera: state.activeCamera === cameraId ? null : state.activeCamera
        }), false, 'removeCamera'),

      setScenes: (scenes) =>
        set({ scenes: Array.isArray(scenes) ? scenes : [] }, false, 'setScenes'),

      setActiveScene: (sceneId) =>
        set({ activeScene: sceneId }, false, 'setActiveScene'),

      updateScene: (sceneId, updates) =>
        set((state) => ({
          scenes: Array.isArray(state.scenes) ? state.scenes.map(scene =>
            scene?.id === sceneId ? { ...scene, ...updates } : scene
          ) : []
        }), false, 'updateScene'),

      addScene: (scene) =>
        set((state) => ({
          scenes: scene ? [...(Array.isArray(state.scenes) ? state.scenes : []), scene] : state.scenes
        }), false, 'addScene'),

      removeScene: (sceneId) =>
        set((state) => ({
          scenes: Array.isArray(state.scenes) ? state.scenes.filter(scene => scene?.id !== sceneId) : [],
          activeScene: state.activeScene === sceneId ? null : state.activeScene
        }), false, 'removeScene'),

      setStreams: (streams) =>
        set({ streams: Array.isArray(streams) ? streams : [] }, false, 'setStreams'),

      setActiveStreams: (streamIds) =>
        set({ activeStreams: Array.isArray(streamIds) ? streamIds : [] }, false, 'setActiveStreams'),

      updateStream: (streamId, updates) =>
        set((state) => ({
          streams: Array.isArray(state.streams) ? state.streams.map(stream =>
            stream?.id === streamId ? { ...stream, ...updates } : stream
          ) : []
        }), false, 'updateStream'),

      addStream: (stream) =>
        set((state) => ({
          streams: stream ? [...(Array.isArray(state.streams) ? state.streams : []), stream] : state.streams
        }), false, 'addStream'),

      removeStream: (streamId) =>
        set((state) => ({
          streams: Array.isArray(state.streams) ? state.streams.filter(stream => stream?.id !== streamId) : [],
          activeStreams: Array.isArray(state.activeStreams) ? state.activeStreams.filter(id => id !== streamId) : []
        }), false, 'removeStream'),

      setCommentaryEnabled: (enabled) =>
        set({ commentaryEnabled: enabled }, false, 'setCommentaryEnabled'),

      setAudioLevel: (level) =>
        set({ audioLevel: level }, false, 'setAudioLevel'),

      // Reset store
      reset: () =>
        set({
          connected: false,
          connectionError: null,
          systemStatus: {
            cameras: { total: 0, online: 0, offline: 0 },
            streams: { active: 0, viewers: 0 },
            system: { cpu: 0, memory: 0, uptime: 0 }
          },
          cameras: [],
          activeCamera: null,
          scenes: [],
          activeScene: null,
          streams: [],
          activeStreams: [],
          commentaryEnabled: false,
          audioLevel: 0,
        }, false, 'reset'),
    }),
    {
      name: 'broadcast-store',
      version: 1,
    }
  )
);