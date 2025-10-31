import React, { useEffect } from 'react';
import { Routes, Route, Navigate } from 'react-router-dom';
import { Box } from '@mui/material';

// Components
import Navigation from './components/Navigation';
import Dashboard from './pages/Dashboard';
import CameraManager from './pages/CameraManager';
import SceneComposer from './pages/SceneComposer';
import StreamManager from './pages/StreamManager';
import CommentaryControl from './pages/CommentaryControl';
import Settings from './pages/Settings';
import LivePreview from './pages/LivePreview';

// Hooks and Services
import { useWebSocket } from './hooks/useWebSocket';
import { useBroadcastStore } from './store/broadcastStore';

function App() {
  const { socket, connected } = useWebSocket();
  const { setConnectionStatus, updateSystemStatus } = useBroadcastStore();

  useEffect(() => {
    setConnectionStatus(connected);
  }, [connected, setConnectionStatus]);

  useEffect(() => {
    if (socket) {
      // Listen for system status updates
      socket.on('system-stats', (stats) => {
        updateSystemStatus(stats);
      });

      // Listen for initial state
      socket.on('initial-state', (state) => {
        // Update store with initial state
        console.log('Received initial state:', state);
      });

      return () => {
        socket.off('system-stats');
        socket.off('initial-state');
      };
    }
  }, [socket, updateSystemStatus]);

  return (
    <Box sx={{ display: 'flex', minHeight: '100vh' }}>
      <Navigation />
      <Box 
        component="main" 
        sx={{ 
          flexGrow: 1, 
          display: 'flex', 
          flexDirection: 'column',
          backgroundColor: 'background.default'
        }}
      >
        <Routes>
          <Route path="/" element={<Navigate to="/dashboard" replace />} />
          <Route path="/dashboard" element={<Dashboard />} />
          <Route path="/cameras" element={<CameraManager />} />
          <Route path="/scenes" element={<SceneComposer />} />
          <Route path="/streaming" element={<StreamManager />} />
          <Route path="/commentary" element={<CommentaryControl />} />
          <Route path="/preview" element={<LivePreview />} />
          <Route path="/settings" element={<Settings />} />
        </Routes>
      </Box>
    </Box>
  );
}

export default App;