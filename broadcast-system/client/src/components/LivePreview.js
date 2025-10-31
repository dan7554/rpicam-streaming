import React, { useState, useEffect, useRef } from 'react';
import {
  Box,
  Card,
  CardContent,
  Typography,
  Button,
  IconButton,
  Slider,
  Chip,
  Grid,
  FormControl,
  InputLabel,
  Select,
  MenuItem
} from '@mui/material';
import {
  PlayArrow,
  Pause,
  VolumeUp,
  VolumeOff,
  Fullscreen,
  FullscreenExit,
  Settings,
  Refresh,
  AspectRatio,
  HighQuality
} from '@mui/icons-material';

const LivePreview = ({ socket }) => {
  const videoRef = useRef(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [volume, setVolume] = useState(80);
  const [isMuted, setIsMuted] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false);
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
        setStreamUrl(url);
        if (videoRef.current) {
          videoRef.current.src = url;
        }
      });

      socket.on('preview-stats', (streamStats) => {
        setStats(streamStats);
      });

      socket.on('preview-error', (errorMsg) => {
        setError(errorMsg);
      });

      // Request initial preview stream
      socket.emit('get-preview-stream');

      return () => {
        socket.off('preview-stream-url');
        socket.off('preview-stats');
        socket.off('preview-error');
      };
    }
  }, [socket]);

  useEffect(() => {
    const video = videoRef.current;
    if (!video) return;

    const handlePlay = () => setIsPlaying(true);
    const handlePause = () => setIsPlaying(false);
    const handleError = (e) => {
      console.error('Video error:', e);
      setError('Failed to load video stream');
      setIsPlaying(false);
    };

    video.addEventListener('play', handlePlay);
    video.addEventListener('pause', handlePause);
    video.addEventListener('error', handleError);

    return () => {
      video.removeEventListener('play', handlePlay);
      video.removeEventListener('pause', handlePause);
      video.removeEventListener('error', handleError);
    };
  }, []);

  const handlePlayPause = () => {
    const video = videoRef.current;
    if (!video) return;

    if (isPlaying) {
      video.pause();
    } else {
      video.play().catch(e => {
        console.error('Play failed:', e);
        setError('Failed to start playback');
      });
    }
  };

  const handleVolumeChange = (event, newValue) => {
    setVolume(newValue);
    if (videoRef.current) {
      videoRef.current.volume = newValue / 100;
    }
  };

  const handleMuteToggle = () => {
    setIsMuted(!isMuted);
    if (videoRef.current) {
      videoRef.current.muted = !isMuted;
    }
  };

  const handleFullscreenToggle = () => {
    const video = videoRef.current;
    if (!video) return;

    if (!isFullscreen) {
      if (video.requestFullscreen) {
        video.requestFullscreen();
      } else if (video.webkitRequestFullscreen) {
        video.webkitRequestFullscreen();
      } else if (video.msRequestFullscreen) {
        video.msRequestFullscreen();
      }
    } else {
      if (document.exitFullscreen) {
        document.exitFullscreen();
      } else if (document.webkitExitFullscreen) {
        document.webkitExitFullscreen();
      } else if (document.msExitFullscreen) {
        document.msExitFullscreen();
      }
    }
  };

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
    
    if (videoRef.current) {
      videoRef.current.load();
    }
  };

  useEffect(() => {
    const handleFullscreenChange = () => {
      setIsFullscreen(!!document.fullscreenElement);
    };

    document.addEventListener('fullscreenchange', handleFullscreenChange);
    document.addEventListener('webkitfullscreenchange', handleFullscreenChange);
    document.addEventListener('msfullscreenchange', handleFullscreenChange);

    return () => {
      document.removeEventListener('fullscreenchange', handleFullscreenChange);
      document.removeEventListener('webkitfullscreenchange', handleFullscreenChange);
      document.removeEventListener('msfullscreenchange', handleFullscreenChange);
    };
  }, []);

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
          <video
            ref={videoRef}
            style={{
              width: '100%',
              height: '100%',
              objectFit: 'contain'
            }}
            autoPlay
            muted={isMuted}
            onLoadedMetadata={() => {
              if (videoRef.current) {
                videoRef.current.volume = volume / 100;
              }
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
            opacity: 0,
            transition: 'opacity 0.3s',
            '&:hover': { opacity: 1 },
            '.video-container:hover &': { opacity: 1 }
          }}
          className="video-overlay-controls"
        >
          <Chip 
            label={`${stats.fps} FPS`} 
            size="small" 
            sx={{ backgroundColor: 'rgba(0,0,0,0.7)', color: 'white' }}
          />
          <Chip 
            label={formatBytes(stats.bitrate)} 
            size="small" 
            sx={{ backgroundColor: 'rgba(0,0,0,0.7)', color: 'white' }}
          />
          <Chip 
            label={stats.resolution} 
            size="small" 
            sx={{ backgroundColor: 'rgba(0,0,0,0.7)', color: 'white' }}
          />
        </Box>

        {/* Bottom Controls Overlay */}
        <Box
          sx={{
            position: 'absolute',
            bottom: 0,
            left: 0,
            right: 0,
            background: 'linear-gradient(transparent, rgba(0,0,0,0.8))',
            p: 2,
            opacity: 0,
            transition: 'opacity 0.3s',
            '&:hover': { opacity: 1 },
            '.video-container:hover &': { opacity: 1 }
          }}
          className="video-controls-overlay"
        >
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
            <IconButton 
              onClick={handlePlayPause} 
              sx={{ color: 'white' }}
              disabled={!streamUrl}
            >
              {isPlaying ? <Pause /> : <PlayArrow />}
            </IconButton>

            <IconButton 
              onClick={handleMuteToggle} 
              sx={{ color: 'white' }}
              disabled={!streamUrl}
            >
              {isMuted ? <VolumeOff /> : <VolumeUp />}
            </IconButton>

            <Box sx={{ width: 100, mx: 1 }}>
              <Slider
                value={volume}
                onChange={handleVolumeChange}
                disabled={!streamUrl || isMuted}
                sx={{
                  color: 'white',
                  '& .MuiSlider-thumb': {
                    width: 16,
                    height: 16,
                    backgroundColor: 'white'
                  },
                  '& .MuiSlider-track': {
                    backgroundColor: 'white'
                  },
                  '& .MuiSlider-rail': {
                    backgroundColor: 'rgba(255,255,255,0.3)'
                  }
                }}
              />
            </Box>

            <Box sx={{ flexGrow: 1 }} />

            <IconButton 
              onClick={handleRefresh} 
              sx={{ color: 'white' }}
            >
              <Refresh />
            </IconButton>

            <IconButton 
              onClick={handleFullscreenToggle} 
              sx={{ color: 'white' }}
              disabled={!streamUrl}
            >
              {isFullscreen ? <FullscreenExit /> : <Fullscreen />}
            </IconButton>
          </Box>
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
                {stats.resolution}
              </Typography>
            </Grid>
            <Grid item xs={6} sm={3}>
              <Typography variant="caption" sx={{ color: '#ccc' }}>
                Frame Rate
              </Typography>
              <Typography variant="body2" sx={{ color: 'white' }}>
                {stats.fps} FPS
              </Typography>
            </Grid>
            <Grid item xs={6} sm={3}>
              <Typography variant="caption" sx={{ color: '#ccc' }}>
                Bitrate
              </Typography>
              <Typography variant="body2" sx={{ color: 'white' }}>
                {formatBytes(stats.bitrate)}
              </Typography>
            </Grid>
            <Grid item xs={6} sm={3}>
              <Typography variant="caption" sx={{ color: '#ccc' }}>
                Latency
              </Typography>
              <Typography variant="body2" sx={{ color: 'white' }}>
                {stats.latency}ms
              </Typography>
            </Grid>
          </Grid>
        </CardContent>
      </Card>
    </Box>
  );
};

export default LivePreview;