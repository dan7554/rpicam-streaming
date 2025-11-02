import React, { useState, useEffect, useRef } from 'react';
import {
  Box,
  Card,
  CardContent,
  Typography,
  Button,
  IconButton,
  Chip,
  Grid,
  FormControl,
  InputLabel,
  Select,
  MenuItem
} from '@mui/material';
import {
  Settings,
  Refresh,
  HighQuality
} from '@mui/icons-material';
import WebRTCPreview from './WebRTCPreview';

const LivePreview = ({ socket }) => {
  const [streamUrl, setStreamUrl] = useState('');
  const [quality, setQuality] = useState('1080p');
  const [aspectRatio, setAspectRatio] = useState('16:9');
  const [stats, setStats] = useState({
    bitrate: 0,
    fps: 0,
    resolution: '1920x1080',
    latency: 0
  });
  const [error, setError] = useState(null);

  const qualityOptions = [
    { value: '1080p', label: '1080p (1920x1080)' },
    { value: '720p', label: '720p (1280x720)' },
    { value: '480p', label: '480p (854x480)' },
    { value: '360p', label: '360p (640x360)' }
  ];

  const aspectRatioOptions = [
    { value: '16:9', label: '16:9 (Widescreen)' },
    { value: '4:3', label: '4:3 (Standard)' },
    { value: '1:1', label: '1:1 (Square)' }
  ];

  useEffect(() => {
    if (socket) {
      socket.on('preview-stream-url', (url) => {
        console.log('📺 LivePreview received preview-stream-url:', url);
        if (url && typeof url === 'string') {
          setStreamUrl(url);
          console.log('✅ Stream URL updated to:', url);
        }
      });

      socket.on('camera-switched', (data) => {
        console.log('🔄 LivePreview received camera-switched:', data);
        // When a camera is switched, request the new preview stream
        console.log('📡 Requesting new preview stream...');
        socket.emit('get-preview-stream');
      });

      socket.on('preview-stats', (streamStats) => {
        if (streamStats && typeof streamStats === 'object') {
          setStats(prevStats => ({
            bitrate: streamStats.bitrate || prevStats.bitrate || 0,
            fps: streamStats.fps || prevStats.fps || 0,
            resolution: streamStats.resolution || prevStats.resolution || '1920x1080',
            latency: streamStats.latency || prevStats.latency || 0,
            ...streamStats
          }));
        }
      });

      socket.on('preview-error', (errorMsg) => {
        console.error('❌ LivePreview received error:', errorMsg);
        if (errorMsg) {
          setError(String(errorMsg));
        }
      });

      socket.on('preview-quality-changed', (quality) => {
        console.log('✅ Preview quality changed to:', quality);
        setQuality(quality);
      });

      // Request initial preview stream
      console.log('🚀 LivePreview requesting initial preview stream...');
      socket.emit('get-preview-stream');

      return () => {
        socket.off('preview-stream-url');
        socket.off('camera-switched');
        socket.off('preview-stats');
        socket.off('preview-error');
        socket.off('preview-quality-changed');
      };
    }
  }, [socket]);

  // Remove the video-specific useEffect since we're using WebRTCPreview

  // Remove video-specific control functions since WebRTCPreview handles its own playback

  const handleQualityChange = (event) => {
    const newQuality = event.target.value;
    setQuality(newQuality);
    
    if (socket) {
      socket.emit('change-preview-quality', newQuality);
    }
  };

  const handleRefresh = () => {
    if (socket) {
      socket.emit('refresh-preview-stream');
    }
    
    // For WebRTC, we'll trigger a reconnection by clearing and resetting the URL
    const currentUrl = streamUrl;
    setStreamUrl('');
    setTimeout(() => setStreamUrl(currentUrl), 100);
  };

  const formatBytes = (bytes) => {
    if (bytes === 0) return '0 bps';
    const k = 1000;
    const sizes = ['bps', 'Kbps', 'Mbps', 'Gbps'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(1)) + ' ' + sizes[i];
  };

  return (
    <Box sx={{ position: 'relative', height: '100%' }}>
      {/* Video Container */}
      <Box 
        sx={{ 
          position: 'relative',
          width: '100%',
          height: '400px',
          backgroundColor: '#000',
          borderRadius: '8px',
          overflow: 'hidden',
          mb: 2
        }}
      >
        {streamUrl ? (
          <WebRTCPreview 
            url={streamUrl}
            style={{
              width: '100%',
              height: '100%',
              objectFit: 'contain'
            }}
          />
        ) : (
          <Box sx={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            height: '100%',
            flexDirection: 'column',
            color: 'white'
          }}>
            <Typography variant="h6" sx={{ mb: 2 }}>
              No Preview Available
            </Typography>
            <Button 
              variant="outlined" 
              startIcon={<Refresh />}
              onClick={handleRefresh}
            >
              Refresh Stream
            </Button>
          </Box>
        )}

        {/* Overlay Controls */}
        <Box
          sx={{
            position: 'absolute',
            top: 8,
            right: 8,
            display: 'flex',
            gap: 1,
            backgroundColor: 'rgba(0,0,0,0.5)',
            borderRadius: 1,
            p: 1
          }}
        >
          <Chip 
            label={`${stats?.fps || 0} FPS`} 
            size="small" 
            sx={{ backgroundColor: 'rgba(0,0,0,0.7)', color: 'white' }}
          />
          <Chip 
            label={formatBytes(stats?.bitrate || 0)} 
            size="small" 
            sx={{ backgroundColor: 'rgba(0,0,0,0.7)', color: 'white' }}
          />
          <Chip 
            label={stats?.resolution || '1920x1080'} 
            size="small" 
            sx={{ backgroundColor: 'rgba(0,0,0,0.7)', color: 'white' }}
          />
        </Box>

        {/* Refresh Button Overlay */}
        <Box
          sx={{
            position: 'absolute',
            bottom: 8,
            right: 8
          }}
        >
          <IconButton 
            onClick={handleRefresh} 
            sx={{ 
              color: 'white',
              backgroundColor: 'rgba(0,0,0,0.5)',
              '&:hover': { backgroundColor: 'rgba(0,0,0,0.7)' }
            }}
          >
            <Refresh />
          </IconButton>
        </Box>

        {/* Error Display */}
        {error && (
          <Box
            sx={{
              position: 'absolute',
              top: '50%',
              left: '50%',
              transform: 'translate(-50%, -50%)',
              backgroundColor: 'rgba(244, 67, 54, 0.9)',
              color: 'white',
              p: 2,
              borderRadius: 1,
              textAlign: 'center'
            }}
          >
            <Typography variant="body2">
              {error}
            </Typography>
            <Button 
              size="small" 
              sx={{ mt: 1, color: 'white' }} 
              onClick={() => setError(null)}
            >
              Dismiss
            </Button>
          </Box>
        )}
      </Box>

      {/* Stream Controls */}
      <Grid container spacing={2}>
        <Grid item xs={12} sm={6} md={3}>
          <FormControl fullWidth size="small">
            <InputLabel sx={{ color: '#ccc' }}>Quality</InputLabel>
            <Select
              value={quality}
              onChange={handleQualityChange}
              label="Quality"
              sx={{
                color: 'white',
                '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
              }}
            >
              {qualityOptions.map((option) => (
                <MenuItem key={option.value} value={option.value}>
                  {option.label}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <FormControl fullWidth size="small">
            <InputLabel sx={{ color: '#ccc' }}>Aspect Ratio</InputLabel>
            <Select
              value={aspectRatio}
              onChange={(e) => setAspectRatio(e.target.value)}
              label="Aspect Ratio"
              sx={{
                color: 'white',
                '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
              }}
            >
              {aspectRatioOptions.map((option) => (
                <MenuItem key={option.value} value={option.value}>
                  {option.label}
                </MenuItem>
              ))}
            </Select>
          </FormControl>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Button
            fullWidth
            variant="outlined"
            startIcon={<Settings />}
            sx={{ height: '40px' }}
          >
            Stream Settings
          </Button>
        </Grid>

        <Grid item xs={12} sm={6} md={3}>
          <Button
            fullWidth
            variant="outlined"
            startIcon={<HighQuality />}
            sx={{ height: '40px' }}
          >
            Advanced
          </Button>
        </Grid>
      </Grid>

      {/* Stream Statistics */}
      <Card sx={{ mt: 2, backgroundColor: '#2d2d30', border: '1px solid #444' }}>
        <CardContent>
          <Typography variant="h6" sx={{ color: 'white', mb: 2 }}>
            Stream Statistics
          </Typography>
          <Grid container spacing={2}>
            <Grid item xs={6} sm={3}>
              <Typography variant="caption" sx={{ color: '#ccc' }}>
                Resolution
              </Typography>
              <Typography variant="body2" sx={{ color: 'white' }}>
                {stats?.resolution || '1920x1080'}
              </Typography>
            </Grid>
            <Grid item xs={6} sm={3}>
              <Typography variant="caption" sx={{ color: '#ccc' }}>
                Frame Rate
              </Typography>
              <Typography variant="body2" sx={{ color: 'white' }}>
                {stats?.fps || 0} FPS
              </Typography>
            </Grid>
            <Grid item xs={6} sm={3}>
              <Typography variant="caption" sx={{ color: '#ccc' }}>
                Bitrate
              </Typography>
              <Typography variant="body2" sx={{ color: 'white' }}>
                {formatBytes(stats?.bitrate || 0)}
              </Typography>
            </Grid>
            <Grid item xs={6} sm={3}>
              <Typography variant="caption" sx={{ color: '#ccc' }}>
                Latency
              </Typography>
              <Typography variant="body2" sx={{ color: 'white' }}>
                {stats?.latency || 0}ms
              </Typography>
            </Grid>
          </Grid>
        </CardContent>
      </Card>
    </Box>
  );
};

export default LivePreview;