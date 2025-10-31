import React, { useEffect, useState } from 'react';
import { Grid, Paper, Typography, Box, Card, CardContent } from '@mui/material';
import { io } from 'socket.io-client';
import CameraManager from '../components/CameraManager';
import SceneComposer from '../components/SceneComposer';
import StreamManager from '../components/StreamManager';
import SystemStats from '../components/SystemStats';
import LivePreview from '../components/LivePreview';

const Dashboard = () => {
  const [socket, setSocket] = useState(null);
  const [systemStats, setSystemStats] = useState({
    cameras: { total: 0, online: 0, offline: 0 },
    streams: { active: 0, viewers: 0 },
    system: { cpu: 0, memory: 0, uptime: 0 }
  });

  useEffect(() => {
    // Initialize socket connection
    const newSocket = io(process.env.REACT_APP_SERVER_URL || 'ws://localhost:3001');
    setSocket(newSocket);

    // Listen for system stats updates
    newSocket.on('system-stats', (stats) => {
      setSystemStats(stats);
    });

    // Request initial stats
    newSocket.emit('get-system-stats');

    return () => {
      newSocket.close();
    };
  }, []);

  return (
    <Box sx={{ flexGrow: 1, p: 3 }}>
      <Typography variant="h4" component="h1" gutterBottom sx={{ color: 'white', mb: 3 }}>
        Broadcast Dashboard
      </Typography>

      <Grid container spacing={3}>
        {/* System Overview */}
        <Grid item xs={12}>
          <SystemStats stats={systemStats} socket={socket} />
        </Grid>

        {/* Live Preview */}
        <Grid item xs={12} lg={8}>
          <Paper sx={{ p: 2, backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
            <Typography variant="h6" component="h2" gutterBottom sx={{ color: 'white' }}>
              Live Preview
            </Typography>
            <LivePreview socket={socket} />
          </Paper>
        </Grid>

        {/* Stream Manager */}
        <Grid item xs={12} lg={4}>
          <StreamManager socket={socket} />
        </Grid>

        {/* Camera Manager */}
        <Grid item xs={12} lg={6}>
          <CameraManager socket={socket} />
        </Grid>

        {/* Scene Composer */}
        <Grid item xs={12} lg={6}>
          <SceneComposer socket={socket} />
        </Grid>
      </Grid>
    </Box>
  );
};

export default Dashboard;