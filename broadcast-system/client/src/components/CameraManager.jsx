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
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  Switch,
  FormControlLabel,
  Alert
} from '@mui/material';
import {
  Videocam,
  VideocamOff,
  Settings,
  Refresh,
  Add,
  Delete,
  Edit
} from '@mui/icons-material';

const CameraManager = ({ socket }) => {
  const [cameras, setCameras] = useState([]);
  const [selectedCamera, setSelectedCamera] = useState(null);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingCamera, setEditingCamera] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);

  // Camera form state
  const [cameraForm, setCameraForm] = useState({
    name: '',
    url: '',
    type: 'rtsp',
    enabled: true,
    position: { x: 0, y: 0 },
    resolution: '1920x1080',
    framerate: 30
  });

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

      // Request initial camera list
      fetchCameras();
    }

    return () => {
      if (socket) {
        socket.off('cameras-updated');
        socket.off('camera-status-changed');
      }
    };
  }, [socket]);

  const fetchCameras = async () => {
    try {
      setLoading(true);
      const response = await fetch('/api/cameras');
      const result = await response.json();
      const data = result.data || result; // Handle both response formats
      setCameras(Array.isArray(data) ? data : []);
    } catch (err) {
      setError('Failed to fetch cameras');
    } finally {
      setLoading(false);
    }
  };

  const handleAddCamera = () => {
    setEditingCamera(null);
    setCameraForm({
      name: '',
      url: '',
      type: 'rtsp',
      enabled: true,
      position: { x: 0, y: 0 },
      resolution: '1920x1080',
      framerate: 30
    });
    setDialogOpen(true);
  };

  const handleEditCamera = (camera) => {
    if (!camera) return;
    
    setEditingCamera(camera);
    setCameraForm({
      name: camera.name || '',
      url: camera.url || '',
      type: camera.type || 'rtsp',
      enabled: camera.enabled !== undefined ? camera.enabled : true,
      position: camera.position || { x: 0, y: 0 },
      resolution: camera.resolution || '1920x1080',
      framerate: camera.framerate || 30
    });
    setDialogOpen(true);
  };

  const handleSaveCamera = async () => {
    try {
      setLoading(true);
      const url = editingCamera 
        ? `/api/cameras/${editingCamera.id}`
        : '/api/cameras';
      
      const method = editingCamera ? 'PUT' : 'POST';
      
      const response = await fetch(url, {
        method,
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(cameraForm),
      });

      if (!response.ok) {
        throw new Error('Failed to save camera');
      }

      setDialogOpen(false);
      fetchCameras();
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleDeleteCamera = async (cameraId) => {
    if (!window.confirm('Are you sure you want to delete this camera?')) {
      return;
    }

    try {
      setLoading(true);
      const response = await fetch(`/api/cameras/${cameraId}`, {
        method: 'DELETE',
      });

      if (!response.ok) {
        throw new Error('Failed to delete camera');
      }

      fetchCameras();
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleSwitchCamera = async (cameraId) => {
    try {
      const response = await fetch(`/api/cameras/${cameraId}/switch`, {
        method: 'POST',
      });

      if (!response.ok) {
        throw new Error('Failed to switch camera');
      }

      setSelectedCamera(cameraId);
    } catch (err) {
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
        <Box>
          <IconButton onClick={fetchCameras} sx={{ color: 'white', mr: 1 }}>
            <Refresh />
          </IconButton>
          <Button 
            variant="contained" 
            startIcon={<Add />}
            onClick={handleAddCamera}
            sx={{ bgcolor: '#1976d2' }}
          >
            Add Camera
          </Button>
        </Box>
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
                      <video 
                        className="video-preview"
                        src={safeCamera.previewUrl}
                        autoPlay
                        muted
                        onError={() => console.log('Video preview error for camera:', safeCamera.id)}
                      />
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
                      <IconButton 
                        sx={{ color: 'white', mr: 1 }}
                        onClick={() => handleEditCamera(safeCamera)}
                      >
                        <Settings />
                      </IconButton>
                    </div>
                  </div>

                  <Typography variant="body2" sx={{ color: '#ccc', mt: 1, fontSize: '0.75rem' }}>
                    {safeCamera.resolution} • {safeCamera.framerate}fps
                  </Typography>
                </CardContent>

                <CardActions sx={{ pt: 0, px: 2, pb: 2 }}>
                  <Button 
                    size="small" 
                    variant={selectedCamera === safeCamera.id ? "contained" : "outlined"}
                    color={selectedCamera === safeCamera.id ? "success" : "primary"}
                    onClick={() => handleSwitchCamera(safeCamera.id)}
                    disabled={safeCamera.status !== 'online'}
                    sx={{ mr: 1, flex: 1 }}
                  >
                    {selectedCamera === safeCamera.id ? 'Active' : 'Switch To'}
                  </Button>
                  <IconButton 
                    size="small" 
                    onClick={() => handleEditCamera(safeCamera)}
                    sx={{ color: '#1976d2' }}
                  >
                    <Edit />
                  </IconButton>
                  <IconButton 
                    size="small" 
                    onClick={() => handleDeleteCamera(safeCamera.id)}
                    sx={{ color: '#f44336' }}
                  >
                    <Delete />
                  </IconButton>
                </CardActions>
              </Card>
            </Grid>
          );
        })}
      </Grid>

      {cameras.length === 0 && !loading && (
        <Box sx={{ textAlign: 'center', py: 4 }}>
          <Typography variant="body1" sx={{ color: '#ccc', mb: 2 }}>
            No cameras configured
          </Typography>
          <Button variant="contained" startIcon={<Add />} onClick={handleAddCamera}>
            Add Your First Camera
          </Button>
        </Box>
      )}

      {/* Add/Edit Camera Dialog */}
      <Dialog open={dialogOpen} onClose={() => setDialogOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          {editingCamera ? 'Edit Camera' : 'Add Camera'}
        </DialogTitle>
        <DialogContent sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          <Grid container spacing={2} sx={{ mt: 1 }}>
            <Grid item xs={12}>
              <TextField
                fullWidth
                label="Camera Name"
                value={cameraForm.name}
                onChange={(e) => setCameraForm({ ...cameraForm, name: e.target.value })}
                sx={{ 
                  '& .MuiInputLabel-root': { color: '#ccc' },
                  '& .MuiOutlinedInput-root': { 
                    color: 'white',
                    '& fieldset': { borderColor: '#555' },
                    '&:hover fieldset': { borderColor: '#777' },
                    '&.Mui-focused fieldset': { borderColor: '#1976d2' }
                  }
                }}
              />
            </Grid>
            <Grid item xs={12}>
              <TextField
                fullWidth
                label="Stream URL"
                value={cameraForm.url}
                onChange={(e) => setCameraForm({ ...cameraForm, url: e.target.value })}
                placeholder="rtsp://camera-ip:554/stream"
                sx={{ 
                  '& .MuiInputLabel-root': { color: '#ccc' },
                  '& .MuiOutlinedInput-root': { 
                    color: 'white',
                    '& fieldset': { borderColor: '#555' },
                    '&:hover fieldset': { borderColor: '#777' },
                    '&.Mui-focused fieldset': { borderColor: '#1976d2' }
                  }
                }}
              />
            </Grid>
            <Grid item xs={6}>
              <TextField
                fullWidth
                label="Resolution"
                value={cameraForm.resolution}
                onChange={(e) => setCameraForm({ ...cameraForm, resolution: e.target.value })}
                sx={{ 
                  '& .MuiInputLabel-root': { color: '#ccc' },
                  '& .MuiOutlinedInput-root': { 
                    color: 'white',
                    '& fieldset': { borderColor: '#555' },
                    '&:hover fieldset': { borderColor: '#777' },
                    '&.Mui-focused fieldset': { borderColor: '#1976d2' }
                  }
                }}
              />
            </Grid>
            <Grid item xs={6}>
              <TextField
                fullWidth
                label="Frame Rate"
                type="number"
                value={cameraForm.framerate}
                onChange={(e) => setCameraForm({ ...cameraForm, framerate: parseInt(e.target.value) })}
                sx={{ 
                  '& .MuiInputLabel-root': { color: '#ccc' },
                  '& .MuiOutlinedInput-root': { 
                    color: 'white',
                    '& fieldset': { borderColor: '#555' },
                    '&:hover fieldset': { borderColor: '#777' },
                    '&.Mui-focused fieldset': { borderColor: '#1976d2' }
                  }
                }}
              />
            </Grid>
            <Grid item xs={12}>
              <FormControlLabel
                control={
                  <Switch
                    checked={cameraForm.enabled}
                    onChange={(e) => setCameraForm({ ...cameraForm, enabled: e.target.checked })}
                    color="primary"
                  />
                }
                label="Enable Camera"
                sx={{ color: 'white' }}
              />
            </Grid>
          </Grid>
        </DialogContent>
        <DialogActions sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          <Button onClick={() => setDialogOpen(false)} sx={{ color: '#ccc' }}>
            Cancel
          </Button>
          <Button 
            onClick={handleSaveCamera} 
            variant="contained"
            disabled={!cameraForm.name || !cameraForm.url}
          >
            {editingCamera ? 'Update' : 'Add'} Camera
          </Button>
        </DialogActions>
      </Dialog>
    </Paper>
  );
};

export default CameraManager;