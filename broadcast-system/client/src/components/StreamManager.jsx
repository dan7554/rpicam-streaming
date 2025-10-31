import React, { useState, useEffect } from 'react';
import {
  Paper,
  Typography,
  Box,
  Button,
  Card,
  CardContent,
  Chip,
  Grid,
  TextField,
  FormControl,
  InputLabel,
  Select,
  MenuItem,
  Dialog,
  DialogTitle,
  DialogContent,
  DialogActions,
  Alert,
  LinearProgress,
  IconButton,
  Tooltip
} from '@mui/material';
import {
  PlayArrow,
  Stop,
  Settings,
  YouTube,
  Facebook,
  Tv,
  Visibility,
  VisibilityOff,
  Refresh,
  Link,
  Error,
  CheckCircle
} from '@mui/icons-material';

const StreamManager = ({ socket }) => {
  const [streams, setStreams] = useState([]);
  const [activeStreams, setActiveStreams] = useState([]);
  const [streamDialogOpen, setStreamDialogOpen] = useState(false);
  const [editingStream, setEditingStream] = useState(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState(null);
  const [streamForm, setStreamForm] = useState({
    name: '',
    platform: 'youtube',
    rtmpUrl: '',
    streamKey: '',
    bitrate: 4000,
    resolution: '1920x1080',
    framerate: 30,
    enabled: true
  });

  const platforms = [
    { id: 'youtube', name: 'YouTube Live', icon: <YouTube />, color: '#ff0000' },
    { id: 'facebook', name: 'Facebook Live', icon: <Facebook />, color: '#1877f2' },
    { id: 'twitch', name: 'Twitch', icon: <Tv />, color: '#9146ff' },
    { id: 'custom', name: 'Custom RTMP', icon: <Link />, color: '#666' }
  ];

  const presets = {
    youtube: {
      rtmpUrl: 'rtmp://a.rtmp.youtube.com/live2',
      bitrate: 4000,
      resolution: '1920x1080',
      framerate: 30
    },
    facebook: {
      rtmpUrl: 'rtmps://live-api-s.facebook.com:443/rtmp',
      bitrate: 4000,
      resolution: '1920x1080',
      framerate: 30
    },
    twitch: {
      rtmpUrl: 'rtmp://live.twitch.tv/live',
      bitrate: 3500,
      resolution: '1920x1080',
      framerate: 30
    }
  };

  useEffect(() => {
    if (socket) {
      socket.on('streams-updated', setStreams);
      socket.on('stream-status-changed', handleStreamStatusChange);
      socket.on('stream-stats', handleStreamStats);
      
      fetchStreams();
    }

    return () => {
      if (socket) {
        socket.off('streams-updated');
        socket.off('stream-status-changed');
        socket.off('stream-stats');
      }
    };
  }, [socket]);

  const handleStreamStatusChange = (streamId, status, stats) => {
    setStreams(prev => prev.map(stream => 
      stream.id === streamId 
        ? { ...stream, status, stats: stats || stream.stats }
        : stream
    ));

    if (status === 'live') {
      setActiveStreams(prev => [...prev.filter(id => id !== streamId), streamId]);
    } else {
      setActiveStreams(prev => prev.filter(id => id !== streamId));
    }
  };

  const handleStreamStats = (streamId, stats) => {
    setStreams(prev => prev.map(stream => 
      stream.id === streamId 
        ? { ...stream, stats }
        : stream
    ));
  };

  const fetchStreams = async () => {
    try {
      setLoading(true);
      const response = await fetch('/api/streaming/streams');
      const result = await response.json();
      const data = result.data || result; // Handle both response formats
      setStreams(Array.isArray(data) ? data : []);
      setActiveStreams(Array.isArray(data) ? data.filter(s => s?.status === 'live').map(s => s?.id).filter(Boolean) : []);
    } catch (err) {
      setError('Failed to fetch streams');
    } finally {
      setLoading(false);
    }
  };

  const handleStartStream = async (streamId) => {
    try {
      const response = await fetch(`/api/streaming/streams/${streamId}/start`, {
        method: 'POST',
      });
      
      if (!response.ok) {
        throw new Error('Failed to start stream');
      }
    } catch (err) {
      setError(err.message);
    }
  };

  const handleStopStream = async (streamId) => {
    try {
      const response = await fetch(`/api/streaming/streams/${streamId}/stop`, {
        method: 'POST',
      });
      
      if (!response.ok) {
        throw new Error('Failed to stop stream');
      }
    } catch (err) {
      setError(err.message);
    }
  };

  const handleAddStream = () => {
    setEditingStream(null);
    setStreamForm({
      name: '',
      platform: 'youtube',
      rtmpUrl: '',
      streamKey: '',
      bitrate: 4000,
      resolution: '1920x1080',
      framerate: 30,
      enabled: true
    });
    setStreamDialogOpen(true);
  };

  const handleEditStream = (stream) => {
    if (!stream) return;
    
    setEditingStream(stream);
    setStreamForm({
      name: stream.name || '',
      platform: stream.platform || 'custom',
      rtmpUrl: stream.rtmpUrl || '',
      streamKey: stream.streamKey || '',
      bitrate: stream.bitrate || 2500,
      resolution: stream.resolution || '1920x1080',
      framerate: stream.framerate || 30,
      enabled: stream.enabled !== false
    });
    setStreamDialogOpen(true);
  };

  const handleSaveStream = async () => {
    try {
      setLoading(true);
      const url = editingStream 
        ? `/api/streaming/streams/${editingStream.id}`
        : '/api/streaming/streams';
      
      const method = editingStream ? 'PUT' : 'POST';
      
      const response = await fetch(url, {
        method,
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify(streamForm),
      });

      if (!response.ok) {
        throw new Error('Failed to save stream');
      }

      setStreamDialogOpen(false);
      fetchStreams();
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleDeleteStream = async (streamId) => {
    if (!window.confirm('Are you sure you want to delete this stream?')) {
      return;
    }

    try {
      const response = await fetch(`/api/streaming/streams/${streamId}`, {
        method: 'DELETE',
      });

      if (!response.ok) {
        throw new Error('Failed to delete stream');
      }

      fetchStreams();
    } catch (err) {
      setError(err.message);
    }
  };

  const handlePlatformChange = (platform) => {
    const preset = presets[platform];
    if (preset) {
      setStreamForm({
        ...streamForm,
        platform,
        rtmpUrl: preset.rtmpUrl,
        bitrate: preset.bitrate,
        resolution: preset.resolution,
        framerate: preset.framerate
      });
    } else {
      setStreamForm({
        ...streamForm,
        platform,
        rtmpUrl: '',
        bitrate: 4000,
        resolution: '1920x1080',
        framerate: 30
      });
    }
  };

  const getStatusColor = (status) => {
    switch (status) {
      case 'live': return 'success';
      case 'starting': return 'warning';
      case 'stopping': return 'warning';
      case 'error': return 'error';
      default: return 'default';
    }
  };

  const getStatusIcon = (status) => {
    switch (status) {
      case 'live': return <CheckCircle />;
      case 'starting': return <PlayArrow />;
      case 'stopping': return <Stop />;
      case 'error': return <Error />;
      default: return <Stop />;
    }
  };

  const formatBytes = (bytes) => {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  };

  const formatDuration = (seconds) => {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    const secs = seconds % 60;
    return `${hours.toString().padStart(2, '0')}:${minutes.toString().padStart(2, '0')}:${secs.toString().padStart(2, '0')}`;
  };

  return (
    <Paper sx={{ p: 2, backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 2 }}>
        <Typography variant="h6" component="h2" sx={{ color: 'white' }}>
          Stream Manager
        </Typography>
        <Box>
          <IconButton onClick={fetchStreams} sx={{ color: 'white', mr: 1 }}>
            <Refresh />
          </IconButton>
          <Button 
            variant="contained" 
            onClick={handleAddStream}
            sx={{ bgcolor: '#1976d2' }}
          >
            Add Stream
          </Button>
        </Box>
      </Box>

      {error && (
        <Alert severity="error" sx={{ mb: 2 }} onClose={() => setError(null)}>
          {error}
        </Alert>
      )}

      {/* Active Streams Summary */}
      {activeStreams.length > 0 && (
        <Card sx={{ mb: 2, backgroundColor: '#2d2d30', border: '1px solid #4caf50' }}>
          <CardContent>
            <Box sx={{ display: 'flex', alignItems: 'center', mb: 1 }}>
              <Chip 
                icon={<PlayArrow />}
                label="LIVE"
                color="success"
                className="live-indicator"
                sx={{ mr: 2 }}
              />
              <Typography variant="h6" sx={{ color: 'white' }}>
                {activeStreams.length} Stream{activeStreams.length > 1 ? 's' : ''} Active
              </Typography>
            </Box>
            <Grid container spacing={2}>
              {activeStreams.map(streamId => {
                const stream = streams.find(s => s.id === streamId);
                if (!stream) return null;
                
                return (
                  <Grid item xs={12} sm={6} key={streamId}>
                    <Box sx={{ 
                      display: 'flex', 
                      justifyContent: 'space-between', 
                      alignItems: 'center',
                      p: 1,
                      backgroundColor: '#1d1d1d',
                      borderRadius: 1
                    }}>
                      <Box>
                        <Typography variant="body2" sx={{ color: 'white' }}>
                          {stream.name}
                        </Typography>
                        <Typography variant="caption" sx={{ color: '#ccc' }}>
                          {stream.stats ? formatDuration(stream.stats.duration) : '00:00:00'} • 
                          {stream.stats ? formatBytes(stream.stats.bytesTransferred) : '0 B'}
                        </Typography>
                      </Box>
                      <Button
                        size="small"
                        variant="outlined"
                        color="error"
                        onClick={() => handleStopStream(streamId)}
                        startIcon={<Stop />}
                      >
                        Stop
                      </Button>
                    </Box>
                  </Grid>
                );
              })}
            </Grid>
          </CardContent>
        </Card>
      )}

      {/* Stream List */}
      <Grid container spacing={2}>
        {streams.map((stream) => {
          // Safely access stream properties with defaults
          const safeStream = {
            id: stream?.id || 'unknown',
            name: stream?.name || 'Unknown Stream',
            platform: stream?.platform || 'custom',
            status: stream?.status || 'offline',
            enabled: stream?.enabled !== false,
            resolution: stream?.resolution || '1920x1080',
            framerate: stream?.framerate || 30,
            bitrate: stream?.bitrate || 2500,
            stats: stream?.stats || null,
            ...stream
          };

          const platform = platforms.find(p => p.id === safeStream.platform);
          const isActive = activeStreams.includes(safeStream.id);
          
          return (
            <Grid item xs={12} key={safeStream.id}>
              <Card sx={{ 
                backgroundColor: '#2d2d30',
                border: isActive ? '1px solid #4caf50' : '1px solid #444',
                opacity: safeStream.enabled ? 1 : 0.6
              }}>
                <CardContent>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                    <Box sx={{ flex: 1 }}>
                      <Box sx={{ display: 'flex', alignItems: 'center', mb: 1 }}>
                        {platform && (
                          <Box sx={{ color: platform.color || 'white', mr: 1 }}>
                            {platform.icon}
                          </Box>
                        )}
                        <Typography variant="h6" sx={{ color: 'white', mr: 2 }}>
                          {safeStream.name}
                        </Typography>
                        <Chip 
                          icon={getStatusIcon(safeStream.status)}
                          label={safeStream.status}
                          color={getStatusColor(safeStream.status)}
                          size="small"
                          className={safeStream.status === 'live' ? 'live-indicator' : ''}
                        />
                      </Box>
                      
                      <Typography variant="body2" sx={{ color: '#ccc', mb: 1 }}>
                        {platform?.name || 'Custom'} • {safeStream.resolution} • {safeStream.framerate}fps • {safeStream.bitrate}kbps
                      </Typography>

                      {safeStream.stats && isActive && (
                        <Box sx={{ mt: 2 }}>
                          <Grid container spacing={2}>
                            <Grid item xs={3}>
                              <Typography variant="caption" sx={{ color: '#ccc' }}>
                                Duration
                              </Typography>
                              <Typography variant="body2" sx={{ color: 'white' }}>
                                {formatDuration(safeStream.stats.duration || 0)}
                              </Typography>
                            </Grid>
                            <Grid item xs={3}>
                              <Typography variant="caption" sx={{ color: '#ccc' }}>
                                Data Sent
                              </Typography>
                              <Typography variant="body2" sx={{ color: 'white' }}>
                                {formatBytes(safeStream.stats.bytesTransferred || 0)}
                              </Typography>
                            </Grid>
                            <Grid item xs={3}>
                              <Typography variant="caption" sx={{ color: '#ccc' }}>
                                FPS
                              </Typography>
                              <Typography variant="body2" sx={{ color: 'white' }}>
                                {stream.stats.fps || 0}
                              </Typography>
                            </Grid>
                            <Grid item xs={3}>
                              <Typography variant="caption" sx={{ color: '#ccc' }}>
                                Bitrate
                              </Typography>
                              <Typography variant="body2" sx={{ color: 'white' }}>
                                {Math.round((stream.stats.bitrate || 0) / 1000)}k
                              </Typography>
                            </Grid>
                          </Grid>
                        </Box>
                      )}
                    </Box>

                    <Box sx={{ display: 'flex', gap: 1, ml: 2 }}>
                      {!isActive ? (
                        <Button
                          variant="contained"
                          color="success"
                          startIcon={<PlayArrow />}
                          onClick={() => handleStartStream(stream.id)}
                          disabled={!stream.enabled || stream.status === 'starting'}
                          className="broadcast-button"
                        >
                          {stream.status === 'starting' ? 'Starting...' : 'Start'}
                        </Button>
                      ) : (
                        <Button
                          variant="contained"
                          color="error"
                          startIcon={<Stop />}
                          onClick={() => handleStopStream(stream.id)}
                          disabled={stream.status === 'stopping'}
                          className="broadcast-button live"
                        >
                          {stream.status === 'stopping' ? 'Stopping...' : 'Stop'}
                        </Button>
                      )}
                      
                      <IconButton 
                        onClick={() => handleEditStream(stream)}
                        sx={{ color: '#1976d2' }}
                      >
                        <Settings />
                      </IconButton>
                    </Box>
                  </Box>
                </CardContent>
              </Card>
            </Grid>
          );
        })}
      </Grid>

      {streams.length === 0 && !loading && (
        <Box sx={{ textAlign: 'center', py: 4 }}>
          <Typography variant="body1" sx={{ color: '#ccc', mb: 2 }}>
            No streams configured
          </Typography>
          <Button variant="contained" onClick={handleAddStream}>
            Add Your First Stream
          </Button>
        </Box>
      )}

      {loading && <LinearProgress sx={{ mt: 2 }} />}

      {/* Add/Edit Stream Dialog */}
      <Dialog open={streamDialogOpen} onClose={() => setStreamDialogOpen(false)} maxWidth="sm" fullWidth>
        <DialogTitle sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          {editingStream ? 'Edit Stream' : 'Add Stream'}
        </DialogTitle>
        <DialogContent sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          <Grid container spacing={2} sx={{ mt: 1 }}>
            <Grid item xs={12}>
              <TextField
                fullWidth
                label="Stream Name"
                value={streamForm.name}
                onChange={(e) => setStreamForm({ ...streamForm, name: e.target.value })}
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
              <FormControl fullWidth>
                <InputLabel sx={{ color: '#ccc' }}>Platform</InputLabel>
                <Select
                  value={streamForm.platform}
                  onChange={(e) => handlePlatformChange(e.target.value)}
                  sx={{
                    color: 'white',
                    '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                    '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                    '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
                  }}
                >
                  {platforms.map((platform) => (
                    <MenuItem key={platform.id} value={platform.id}>
                      <Box sx={{ display: 'flex', alignItems: 'center' }}>
                        <Box sx={{ color: platform.color, mr: 1 }}>
                          {platform.icon}
                        </Box>
                        {platform.name}
                      </Box>
                    </MenuItem>
                  ))}
                </Select>
              </FormControl>
            </Grid>

            <Grid item xs={12}>
              <TextField
                fullWidth
                label="RTMP URL"
                value={streamForm.rtmpUrl}
                onChange={(e) => setStreamForm({ ...streamForm, rtmpUrl: e.target.value })}
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
                label="Stream Key"
                type="password"
                value={streamForm.streamKey}
                onChange={(e) => setStreamForm({ ...streamForm, streamKey: e.target.value })}
                InputProps={{
                  endAdornment: (
                    <IconButton 
                      onClick={() => {
                        const input = document.querySelector('input[type="password"]');
                        input.type = input.type === 'password' ? 'text' : 'password';
                      }}
                      sx={{ color: '#ccc' }}
                    >
                      <Visibility />
                    </IconButton>
                  )
                }}
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

            <Grid item xs={4}>
              <TextField
                fullWidth
                label="Bitrate (kbps)"
                type="number"
                value={streamForm.bitrate}
                onChange={(e) => setStreamForm({ ...streamForm, bitrate: parseInt(e.target.value) })}
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

            <Grid item xs={4}>
              <TextField
                fullWidth
                label="Resolution"
                value={streamForm.resolution}
                onChange={(e) => setStreamForm({ ...streamForm, resolution: e.target.value })}
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

            <Grid item xs={4}>
              <TextField
                fullWidth
                label="Frame Rate"
                type="number"
                value={streamForm.framerate}
                onChange={(e) => setStreamForm({ ...streamForm, framerate: parseInt(e.target.value) })}
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
          </Grid>
        </DialogContent>
        <DialogActions sx={{ bgcolor: '#1d1d1d', color: 'white' }}>
          <Button onClick={() => setStreamDialogOpen(false)} sx={{ color: '#ccc' }}>
            Cancel
          </Button>
          <Button 
            onClick={handleSaveStream} 
            variant="contained"
            disabled={!streamForm.name || !streamForm.rtmpUrl || !streamForm.streamKey}
          >
            {editingStream ? 'Update' : 'Add'} Stream
          </Button>
        </DialogActions>
      </Dialog>
    </Paper>
  );
};

export default StreamManager;