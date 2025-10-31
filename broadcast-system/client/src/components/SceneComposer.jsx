import React, { useState, useEffect } from 'react';
import {
  Paper,
  Typography,
  Grid,
  Card,
  CardContent,
  Button,
  Box,
  Chip,
  IconButton,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  TextField,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Slider
} from '@mui/material';
import {
  PlayArrow,
  Stop,
  Settings,
  Fullscreen,
  Add,
  Edit,
  Delete
} from '@mui/icons-material';

const SceneComposer = ({ socket }) => {
  const [scenes, setScenes] = useState([]);
  const [activeScene, setActiveScene] = useState(null);
  const [cameras, setCameras] = useState([]);
  const [dialogOpen, setDialogOpen] = useState(false);
  const [editingScene, setEditingScene] = useState(null);
  const [sceneForm, setSceneForm] = useState({
    name: '',
    layout: 'single',
    cameras: [],
    transition: 'fade',
    duration: 1000
  });

  const sceneLayouts = [
    { id: 'single', name: 'Single Camera', slots: 1 },
    { id: 'side-by-side', name: 'Side by Side', slots: 2 },
    { id: 'picture-in-picture', name: 'Picture in Picture', slots: 2 },
    { id: 'quad', name: 'Quad Split', slots: 4 },
    { id: 'triple', name: 'Triple Layout', slots: 3 },
    { id: 'custom', name: 'Custom Layout', slots: 0 }
  ];

  const transitionTypes = [
    { id: 'cut', name: 'Cut (Instant)' },
    { id: 'fade', name: 'Fade' },
    { id: 'slide-left', name: 'Slide Left' },
    { id: 'slide-right', name: 'Slide Right' },
    { id: 'zoom', name: 'Zoom' },
    { id: 'dissolve', name: 'Dissolve' }
  ];

  useEffect(() => {
    if (socket) {
      socket.on('scenes-updated', setScenes);
      socket.on('active-scene-changed', setActiveScene);
      socket.on('cameras-updated', (data) => setCameras(Array.isArray(data) ? data : []));
      
      fetchScenes();
      fetchCameras();
    }

    return () => {
      if (socket) {
        socket.off('scenes-updated');
        socket.off('active-scene-changed');
        socket.off('cameras-updated');
      }
    };
  }, [socket]);

  const fetchScenes = async () => {
    try {
      const response = await fetch('/api/scenes');
      const data = await response.json();
      setScenes(data.data.scenes);
    } catch (err) {
      console.error('Failed to fetch scenes:', err);
    }
  };

  const fetchCameras = async () => {
    try {
      const response = await fetch('/api/cameras');
      const result = await response.json();
      const data = result.data || result; // Handle both response formats
      setCameras(Array.isArray(data) ? data.filter(cam => cam.status === 'online') : []);
    } catch (err) {
      console.error('Failed to fetch cameras:', err);
    }
  };

  const handleSwitchScene = async (sceneId) => {
    try {
      const response = await fetch(`/api/scenes/${sceneId}/switch`, {
        method: 'POST',
      });
      
      if (response.ok) {
        setActiveScene(sceneId);
      }
    } catch (err) {
      console.error('Failed to switch scene:', err);
    }
  };

  const handleAddScene = () => {
    setEditingScene(null);
    setSceneForm({
      name: '',
      layout: 'single',
      cameras: [],
      transition: 'fade',
      duration: 1000
    });
    setDialogOpen(true);
  };

  const handleEditScene = (scene) => {
    if (!scene) return;
    
    setEditingScene(scene);
    setSceneForm({
      name: scene.name || '',
      layout: scene.layout || 'single',
      cameras: scene.cameras || [],
      transition: scene.transition || 'fade',
      duration: scene.duration || 1000
    });
    setDialogOpen(true);
  };

  const handleSaveScene = async () => {
    try {
      const url = editingScene 
        ? `/api/scenes/${editingScene.id}`
        : '/api/scenes';
      
      const method = editingScene ? 'PUT' : 'POST';
      
      const response = await fetch(url, {
        method,
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(sceneForm),
      });

      if (response.ok) {
        setDialogOpen(false);
        fetchScenes();
      }
    } catch (err) {
      console.error('Failed to save scene:', err);
    }
  };

  const handleDeleteScene = async (sceneId) => {
    if (!window.confirm('Are you sure you want to delete this scene?')) {
      return;
    }

    try {
      const response = await fetch(`/api/scenes/${sceneId}`, {
        method: 'DELETE',
      });

      if (response.ok) {
        fetchScenes();
      }
    } catch (err) {
      console.error('Failed to delete scene:', err);
    }
  };

  const renderScenePreview = (scene) => {
    const layout = sceneLayouts.find(l => l.id === scene.layout);
    const sceneWidth = 240;
    const sceneHeight = 135;

    const getSlotPosition = (slotIndex, totalSlots, layoutType) => {
      const positions = {
        single: [{ x: 0, y: 0, w: 100, h: 100 }],
        'side-by-side': [
          { x: 0, y: 0, w: 50, h: 100 },
          { x: 50, y: 0, w: 50, h: 100 }
        ],
        'picture-in-picture': [
          { x: 0, y: 0, w: 100, h: 100 },
          { x: 70, y: 70, w: 25, h: 25 }
        ],
        quad: [
          { x: 0, y: 0, w: 50, h: 50 },
          { x: 50, y: 0, w: 50, h: 50 },
          { x: 0, y: 50, w: 50, h: 50 },
          { x: 50, y: 50, w: 50, h: 50 }
        ],
        triple: [
          { x: 0, y: 0, w: 50, h: 100 },
          { x: 50, y: 0, w: 50, h: 50 },
          { x: 50, y: 50, w: 50, h: 50 }
        ]
      };

      return positions[layoutType]?.[slotIndex] || { x: 0, y: 0, w: 100, h: 100 };
    };

    return (
      <div className="scene-layout-preview">
        {Array.from({ length: layout?.slots || 1 }).map((_, index) => {
          const position = getSlotPosition(index, layout?.slots || 1, scene.layout);
          const camera = scene.cameras?.[index];
          const cameraInfo = cameras.find(c => c.id === camera?.cameraId);

          return (
            <div
              key={index}
              className="scene-camera-slot"
              style={{
                left: `${position.x}%`,
                top: `${position.y}%`,
                width: `${position.w}%`,
                height: `${position.h}%`,
              }}
            >
              {cameraInfo ? cameraInfo.name : `Slot ${index + 1}`}
            </div>
          );
        })}
      </div>
    );
  };

  const selectedLayout = sceneLayouts.find(l => l.id === sceneForm.layout);
  
  return (
    <Paper sx={{ p: 2, backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2 }}>
        <Typography variant="h6" component="h2" sx={{ color: 'white' }}>
          Scene Composer
        </Typography>
        <Button 
          variant="contained" 
          startIcon={<Add />}
          onClick={handleAddScene}
          sx={{ bgcolor: '#1976d2' }}
        >
          Add Scene
        </Button>
      </Box>

      <Grid container spacing={2}>
        {scenes?.map((scene) => (
          <Grid item xs={12} sm={6} md={4} key={scene.id}>
            <Card 
              sx={{ 
                backgroundColor: '#2d2d30',
                border: activeScene === scene.id ? '2px solid #4caf50' : '1px solid #444',
                '&:hover': { borderColor: '#1976d2' }
              }}
            >
              <CardContent sx={{ pb: 1 }}>
                <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 1 }}>
                  <Typography variant="h6" component="h3" sx={{ color: 'white', fontSize: '1rem' }}>
                    {scene.name}
                  </Typography>
                  {activeScene === scene.id && (
                    <Chip 
                      label="Active" 
                      color="success" 
                      size="small"
                      className="live-indicator"
                    />
                  )}
                </Box>

                {renderScenePreview(scene)}

                <Box sx={{ mt: 1, display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
                  <Typography variant="body2" sx={{ color: '#ccc', fontSize: '0.75rem' }}>
                    {sceneLayouts.find(l => l.id === scene.layout)?.name}
                  </Typography>
                  <Typography variant="body2" sx={{ color: '#ccc', fontSize: '0.75rem' }}>
                    {scene.cameras?.length || 0} cameras
                  </Typography>
                </Box>
              </CardContent>

              <Box sx={{ px: 2, pb: 2, display: 'flex', gap: 1 }}>
                <Button
                  size="small"
                  variant={activeScene === scene.id ? "contained" : "outlined"}
                  color={activeScene === scene.id ? "success" : "primary"}
                  startIcon={activeScene === scene.id ? <Stop /> : <PlayArrow />}
                  onClick={() => handleSwitchScene(scene.id)}
                  sx={{ flex: 1 }}
                >
                  {activeScene === scene.id ? 'Active' : 'Switch'}
                </Button>
                <IconButton 
                  size="small" 
                  onClick={() => handleEditScene(scene)}
                  sx={{ color: '#1976d2' }}
                >
                  <Edit />
                </IconButton>
                <IconButton 
                  size="small" 
                  onClick={() => handleDeleteScene(scene?.id)}
                  sx={{ color: '#f44336' }}
                >
                  <Delete />
                </IconButton>
              </Box>
            </Card>
          </Grid>
        ))}
      </Grid>

      {(scenes?.length || 0) === 0 && (
        <Box sx={{ textAlign: 'center', py: 4 }}>
          <Typography variant="body1" sx={{ color: '#ccc', mb: 2 }}>
            No scenes configured
          </Typography>
          <Button variant="contained" startIcon={<Add />} onClick={handleAddScene}>
            Create Your First Scene
          </Button>
        </Box>
      )}

      {/* Add/Edit Scene Dialog */}
      <Dialog open={dialogOpen} onClose={() => setDialogOpen(false)} maxWidth="md" fullWidth>
        <DialogTitle sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          {editingScene ? 'Edit Scene' : 'Create Scene'}
        </DialogTitle>
        <DialogContent sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          <Grid container spacing={3} sx={{ mt: 1 }}>
            <Grid item xs={12} md={6}>
              <TextField
                fullWidth
                label="Scene Name"
                value={sceneForm.name}
                onChange={(e) => setSceneForm({ ...sceneForm, name: e.target.value })}
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
            <Grid item xs={12} md={6}>
              <FormControl fullWidth>
                <InputLabel sx={{ color: '#ccc' }}>Layout</InputLabel>
                <Select
                  value={sceneForm.layout}
                  onChange={(e) => setSceneForm({ ...sceneForm, layout: e.target.value, cameras: [] })}
                  sx={{
                    color: 'white',
                    '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                    '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                    '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
                  }}
                >
                  {sceneLayouts.map((layout) => (
                    <MenuItem key={layout.id} value={layout.id}>
                      {layout.name}
                    </MenuItem>
                  ))}
                </Select>
              </FormControl>
            </Grid>

            {/* Camera Assignment */}
            {selectedLayout && selectedLayout.slots > 0 && (
              <Grid item xs={12}>
                <Typography variant="h6" sx={{ color: 'white', mb: 2 }}>
                  Camera Assignment
                </Typography>
                <Grid container spacing={2}>
                  {Array.from({ length: selectedLayout.slots }).map((_, index) => (
                    <Grid item xs={12} sm={6} key={index}>
                      <FormControl fullWidth>
                        <InputLabel sx={{ color: '#ccc' }}>Slot {index + 1}</InputLabel>
                        <Select
                          value={sceneForm.cameras[index]?.cameraId || ''}
                          onChange={(e) => {
                            const newCameras = [...sceneForm.cameras];
                            newCameras[index] = { cameraId: e.target.value };
                            setSceneForm({ ...sceneForm, cameras: newCameras });
                          }}
                          sx={{
                            color: 'white',
                            '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                            '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                            '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
                          }}
                        >
                          <MenuItem value="">
                            <em>None</em>
                          </MenuItem>
                          {cameras.map((camera) => (
                            <MenuItem key={camera?.id || `camera-${Math.random()}`} value={camera?.id || ''}>
                              {camera?.name || 'Unknown Camera'}
                            </MenuItem>
                          ))}
                        </Select>
                      </FormControl>
                    </Grid>
                  ))}
                </Grid>
              </Grid>
            )}

            {/* Transition Settings */}
            <Grid item xs={12} sm={6}>
              <FormControl fullWidth>
                <InputLabel sx={{ color: '#ccc' }}>Transition Type</InputLabel>
                <Select
                  value={sceneForm.transition}
                  onChange={(e) => setSceneForm({ ...sceneForm, transition: e.target.value })}
                  sx={{
                    color: 'white',
                    '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                    '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                    '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
                  }}
                >
                  {transitionTypes.map((transition) => (
                    <MenuItem key={transition.id} value={transition.id}>
                      {transition.name}
                    </MenuItem>
                  ))}
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} sm={6}>
              <Typography sx={{ color: '#ccc', mb: 1 }}>
                Transition Duration: {sceneForm.duration}ms
              </Typography>
              <Slider
                value={sceneForm.duration}
                onChange={(e, value) => setSceneForm({ ...sceneForm, duration: value })}
                min={0}
                max={3000}
                step={100}
                sx={{
                  color: '#1976d2',
                  '& .MuiSlider-thumb': {
                    backgroundColor: '#1976d2',
                  },
                  '& .MuiSlider-track': {
                    backgroundColor: '#1976d2',
                  },
                  '& .MuiSlider-rail': {
                    backgroundColor: '#555',
                  },
                }}
              />
            </Grid>

            {/* Preview */}
            {selectedLayout && (
              <Grid item xs={12}>
                <Typography variant="h6" sx={{ color: 'white', mb: 2 }}>
                  Preview
                </Typography>
                {renderScenePreview(sceneForm)}
              </Grid>
            )}
          </Grid>
        </DialogContent>
        <DialogActions sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          <Button onClick={() => setDialogOpen(false)} sx={{ color: '#ccc' }}>
            Cancel
          </Button>
          <Button 
            onClick={handleSaveScene} 
            variant="contained"
            disabled={!sceneForm.name || !sceneForm.layout}
          >
            {editingScene ? 'Update' : 'Create'} Scene
          </Button>
        </DialogActions>
      </Dialog>
    </Paper>
  );
};

export default SceneComposer;