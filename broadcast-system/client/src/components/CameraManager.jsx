import React, { useState, useEffect } from 'react';
import {
  Paper,
  Typography,
  Grid,
  Card,
  CardContent,
  CardActions,
  Button,
  Chip,
  Box,
  IconButton,
  Alert
} from '@mui/material';
import {
  Videocam,
  VideocamOff,
  Refresh
} from '@mui/icons-material';
import WebRTCPreview from './WebRTCPreview';

const CameraManager = ({ socket }) => {
  const [cameras, setCameras] = useState([]);
  const [selectedCamera, setSelectedCamera] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  // Auto-discovery only - no manual camera management

  useEffect(() => {
    if (socket) {
      // Listen for camera updates
      socket.on('cameras-updated', (updatedCameras) => {
        setCameras(Array.isArray(updatedCameras) ? updatedCameras : []);
      });

      socket.on('camera-status-changed', (cameraId, status) => {
        setCameras(prev => Array.isArray(prev) ? prev.map(cam => 
          cam.id === cameraId ? { ...cam, status } : cam
        ) : []);
      });

      socket.on('camera-switched', (data) => {
        setSelectedCamera(data.cameraId);
      });

      // Request initial camera list
      fetchCameras();
    }

    return () => {
      if (socket) {
        socket.off('cameras-updated');
        socket.off('camera-status-changed');
        socket.off('camera-switched');
      }
    };
  }, [socket]);

  const fetchCameras = async () => {
    try {
      setLoading(true);
      const response = await fetch('/api/cameras');
      const result = await response.json();
      const data = result.data || result; // Handle both response formats

      console.log('data', data)

      setCameras(Array.isArray(data) ? data : []);
    } catch (err) {
      setError('Failed to fetch cameras');
    } finally {
      setLoading(false);
    }
  };

  const handleSwitchCamera = async (cameraId) => {
    try {
      console.log('🔄 Client switching to camera:', cameraId);
      // Use WebSocket if available, otherwise fall back to HTTP
      if (socket) {
        console.log('📡 Emitting switch-camera event via WebSocket');
        socket.emit('switch-camera', { cameraId });
      } else {
        console.log('🌐 Using HTTP fallback for camera switch');
        const response = await fetch(`/api/cameras/${cameraId}/switch`, {
          method: 'POST',
        });

        if (!response.ok) {
          throw new Error('Failed to switch camera');
        }
      }

      setSelectedCamera(cameraId);
      console.log('✅ Selected camera updated to:', cameraId);
    } catch (err) {
      console.error('❌ Failed to switch camera:', err);
      setError(err.message);
    }
  };

  const getStatusColor = (status) => {
    switch (status) {
      case 'online': return 'success';
      case 'offline': return 'error';
      case 'connecting': return 'warning';
      default: return 'default';
    }
  };

  const getStatusIcon = (status) => {
    return status === 'online' ? <Videocam /> : <VideocamOff />;
  };

  return (
    <Paper sx={{ p: 2, backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2 }}>
        <Typography variant="h6" component="h2" sx={{ color: 'white' }}>
          Camera Manager
        </Typography>
        <IconButton onClick={fetchCameras} sx={{ color: 'white' }}>
          <Refresh />
        </IconButton>
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      <Grid container spacing={2}>
        {cameras.map((camera) => {
          // Safely access camera properties with defaults
          const safeCamera = {
            id: camera?.id || 'unknown',
            name: camera?.name || 'Unknown Camera',
            status: camera?.status || 'offline',
            previewUrl: camera?.previewUrl || '',
            resolution: camera?.resolution || '1920x1080',
            framerate: camera?.framerate || 30,
            ...camera
          };

          console.log('safeCamera', safeCamera);

          return (
            <Grid item xs={12} sm={6} md={4} key={safeCamera.id}>
              <Card 
                className={`camera-card ${selectedCamera === safeCamera.id ? 'active' : ''} ${safeCamera.status === 'offline' ? 'offline' : ''}`}
              >
                <CardContent sx={{ pb: 1 }}>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                    <Typography variant="h6" component="h3" sx={{ color: 'white', fontSize: '1rem' }}>
                      {safeCamera.name}
                    </Typography>
                    <Chip 
                      icon={getStatusIcon(safeCamera.status)}
                      label={safeCamera.status}
                      color={getStatusColor(safeCamera.status)}
                      size="small"
                    />
                  </Box>

                  <div className="video-preview-container">
                    {safeCamera.status === 'online' ? (
                      safeCamera.type === 'webrtc' ? (
                        <WebRTCPreview 
                          url={safeCamera.previewUrl}
                          className="video-preview"
                        />
                      ) : (
                        <video 
                          className="video-preview"
                          src={safeCamera.previewUrl}
                          autoPlay
                          muted
                          onError={() => console.log('Video preview error for camera:', safeCamera.id)}
                        />
                      )
                    ) : (
                      <Box sx={{ 
                        display: 'flex', 
                        alignItems: 'center', 
                        justifyContent: 'center',
                        height: '100%',
                        color: 'white',
                        flexDirection: 'column'
                      }}>
                        <VideocamOff sx={{ fontSize: 40, mb: 1 }} />
                        <Typography variant="body2">
                          {safeCamera.status === 'connecting' ? 'Connecting...' : 'Offline'}
                        </Typography>
                      </Box>
                    )}
                    
                    <div className="video-preview-overlay">
                    </div>
                  </div>

                  <Typography variant="body2" sx={{ color: '#ccc', mt: 1, fontSize: '0.75rem' }}>
                    {safeCamera?.settings?.resolution} • {safeCamera?.settings?.framerate}fps
                  </Typography>
                </CardContent>

                <CardActions sx={{ pt: 0, px: 2, pb: 2 }}>
                  <Button 
                    size="small" 
                    variant={selectedCamera === safeCamera.id ? "contained" : "outlined"}
                    color={selectedCamera === safeCamera.id ? "success" : "primary"}
                    onClick={() => handleSwitchCamera(safeCamera.id)}
                    disabled={safeCamera.status !== 'online'}
                    sx={{ flex: 1 }}
                  >
                    {selectedCamera === safeCamera.id ? 'Active' : 'Switch To'}
                  </Button>
                </CardActions>
              </Card>
            </Grid>
          );
        })}
      </Grid>

      {cameras.length === 0 && !loading && (
        <Box sx={{ textAlign: 'center', py: 4 }}>
          <Typography variant="body1" sx={{ color: '#ccc' }}>
            Waiting for auto-discovery... Make sure MediaMTX streams are active.
          </Typography>
        </Box>
      )}
    </Paper>
  );
};

export default CameraManager;