import React, { useState, useEffect } from 'react';
import {
  Box,
  Paper,
  Typography,
  Button,
  Slider,
  Switch,
  FormControlLabel,
  Card,
  CardContent,
  Grid,
  Chip,
  IconButton
} from '@mui/material';
import {
  Mic,
  MicOff,
  VolumeUp,
  VolumeOff,
  PlayArrow,
  Stop,
  Settings,
  FiberManualRecord
} from '@mui/icons-material';
import { useBroadcastStore } from '../store/broadcastStore';
import { useWebSocket } from '../hooks/useWebSocket';

const CommentaryControl = () => {
  const { socket } = useWebSocket();
  const store = useBroadcastStore();
  
  // Safely destructure store values with defaults
  const commentaryEnabled = store?.commentaryEnabled || false;
  const audioLevel = store?.audioLevel || 0;
  const setCommentaryEnabled = store?.setCommentaryEnabled || (() => {});
  const setAudioLevel = store?.setAudioLevel || (() => {});
  
  const [micEnabled, setMicEnabled] = useState(false);
  const [volume, setVolume] = useState(80);
  const [isRecording, setIsRecording] = useState(false);
  const [pushToTalk, setPushToTalk] = useState(false);
  const [audioStats, setAudioStats] = useState({
    inputLevel: 0,
    outputLevel: 0,
    sampleRate: 48000,
    bitrate: 128
  });

  useEffect(() => {
    if (socket) {
      socket.on('commentary-stats', (stats) => {
        if (stats && typeof stats === 'object') {
          setAudioStats(prevStats => ({
            inputLevel: stats.inputLevel !== undefined ? stats.inputLevel : prevStats.inputLevel,
            outputLevel: stats.outputLevel !== undefined ? stats.outputLevel : prevStats.outputLevel,
            sampleRate: stats.sampleRate || prevStats.sampleRate,
            bitrate: stats.bitrate || prevStats.bitrate,
            ...stats
          }));
        }
      });
      
      socket.on('audio-level', (level) => {
        if (typeof level === 'number') {
          setAudioLevel(level);
        }
      });
      
      return () => {
        socket.off('commentary-stats');
        socket.off('audio-level');
      };
    }
  }, [socket, setAudioLevel]);

  const handleToggleMic = () => {
    const newState = !micEnabled;
    setMicEnabled(newState);
    
    if (socket) {
      socket.emit('toggle-microphone', newState);
    }
  };

  const handleVolumeChange = (event, newValue) => {
    setVolume(newValue);
    
    if (socket) {
      socket.emit('set-commentary-volume', newValue);
    }
  };

  const handleStartRecording = () => {
    setIsRecording(true);
    
    if (socket) {
      socket.emit('start-commentary-recording');
    }
  };

  const handleStopRecording = () => {
    setIsRecording(false);
    
    if (socket) {
      socket.emit('stop-commentary-recording');
    }
  };

  const handleToggleCommentary = () => {
    const newState = !commentaryEnabled;
    setCommentaryEnabled(newState);
    
    if (socket) {
      socket.emit('toggle-commentary', newState);
    }
  };

  return (
    <Box sx={{ p: 3 }}>
      <Typography variant="h4" component="h1" gutterBottom sx={{ color: 'white', mb: 3 }}>
        Commentary Control
      </Typography>

      <Grid container spacing={3}>
        {/* Main Controls */}
        <Grid item xs={12} md={6}>
          <Paper sx={{ p: 3, backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
            <Typography variant="h6" component="h2" gutterBottom sx={{ color: 'white' }}>
              Audio Controls
            </Typography>

            <Box sx={{ mb: 3 }}>
              <FormControlLabel
                control={
                  <Switch
                    checked={commentaryEnabled}
                    onChange={handleToggleCommentary}
                    color="primary"
                  />
                }
                label="Enable Commentary"
                sx={{ color: 'white', mb: 2, display: 'block' }}
              />

              <FormControlLabel
                control={
                  <Switch
                    checked={pushToTalk}
                    onChange={(e) => setPushToTalk(e.target.checked)}
                    color="primary"
                  />
                }
                label="Push to Talk Mode"
                sx={{ color: 'white', display: 'block' }}
              />
            </Box>

            <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, mb: 3 }}>
              <Button
                variant={micEnabled ? "contained" : "outlined"}
                color={micEnabled ? "success" : "primary"}
                startIcon={micEnabled ? <Mic /> : <MicOff />}
                onClick={handleToggleMic}
                size="large"
                sx={{ minWidth: 140 }}
              >
                {micEnabled ? 'Mic On' : 'Mic Off'}
              </Button>

              <Chip
                icon={<FiberManualRecord />}
                label={isRecording ? 'Recording' : 'Standby'}
                color={isRecording ? 'error' : 'secondary'}
                className={isRecording ? 'live-indicator' : ''}
              />
            </Box>

            <Box sx={{ mb: 3 }}>
              <Typography gutterBottom sx={{ color: 'white' }}>
                Commentary Volume: {volume}%
              </Typography>
              <Slider
                value={volume}
                onChange={handleVolumeChange}
                disabled={!commentaryEnabled}
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
            </Box>

            <Box sx={{ display: 'flex', gap: 2 }}>
              <Button
                variant={isRecording ? "contained" : "outlined"}
                color={isRecording ? "error" : "primary"}
                startIcon={isRecording ? <Stop /> : <PlayArrow />}
                onClick={isRecording ? handleStopRecording : handleStartRecording}
                disabled={!commentaryEnabled || !micEnabled}
              >
                {isRecording ? 'Stop Recording' : 'Start Recording'}
              </Button>

              <IconButton sx={{ color: '#1976d2' }}>
                <Settings />
              </IconButton>
            </Box>
          </Paper>
        </Grid>

        {/* Audio Levels */}
        <Grid item xs={12} md={6}>
          <Paper sx={{ p: 3, backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
            <Typography variant="h6" component="h2" gutterBottom sx={{ color: 'white' }}>
              Audio Levels
            </Typography>

            <Grid container spacing={2}>
              <Grid item xs={6}>
                <Typography variant="body2" sx={{ color: '#ccc', mb: 1 }}>
                  Input Level
                </Typography>
                <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                  <Box sx={{ flex: 1, height: 20, backgroundColor: '#333', borderRadius: 1, overflow: 'hidden' }}>
                    <Box
                      sx={{
                        height: '100%',
                        width: `${audioStats?.inputLevel || 0}%`,
                        backgroundColor: (audioStats?.inputLevel || 0) > 80 ? '#f44336' : (audioStats?.inputLevel || 0) > 60 ? '#ff9800' : '#4caf50',
                        transition: 'width 0.1s ease',
                      }}
                    />
                  </Box>
                  <Typography variant="caption" sx={{ color: 'white', minWidth: 30 }}>
                    {Math.round(audioStats?.inputLevel || 0)}%
                  </Typography>
                </Box>
              </Grid>

              <Grid item xs={6}>
                <Typography variant="body2" sx={{ color: '#ccc', mb: 1 }}>
                  Output Level
                </Typography>
                <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
                  <Box sx={{ flex: 1, height: 20, backgroundColor: '#333', borderRadius: 1, overflow: 'hidden' }}>
                    <Box
                      sx={{
                        height: '100%',
                        width: `${audioStats?.outputLevel || 0}%`,
                        backgroundColor: (audioStats?.outputLevel || 0) > 80 ? '#f44336' : (audioStats?.outputLevel || 0) > 60 ? '#ff9800' : '#4caf50',
                        transition: 'width 0.1s ease',
                      }}
                    />
                  </Box>
                  <Typography variant="caption" sx={{ color: 'white', minWidth: 30 }}>
                    {Math.round(audioStats?.outputLevel || 0)}%
                  </Typography>
                </Box>
              </Grid>
            </Grid>

            <Box sx={{ mt: 3 }}>
              <Typography variant="h6" component="h3" gutterBottom sx={{ color: 'white' }}>
                Audio Settings
              </Typography>
              <Grid container spacing={2}>
                <Grid item xs={6}>
                  <Typography variant="caption" sx={{ color: '#ccc' }}>
                    Sample Rate:
                  </Typography>
                  <Typography variant="body2" sx={{ color: 'white' }}>
                    {audioStats?.sampleRate || 48000} Hz
                  </Typography>
                </Grid>
                <Grid item xs={6}>
                  <Typography variant="caption" sx={{ color: '#ccc' }}>
                    Bitrate:
                  </Typography>
                  <Typography variant="body2" sx={{ color: 'white' }}>
                    {audioStats?.bitrate || 128} kbps
                  </Typography>
                </Grid>
              </Grid>
            </Box>
          </Paper>
        </Grid>

        {/* Quick Actions */}
        <Grid item xs={12}>
          <Card sx={{ backgroundColor: '#2d2d30', border: '1px solid #444' }}>
            <CardContent>
              <Typography variant="h6" sx={{ color: 'white', mb: 2 }}>
                Quick Actions
              </Typography>
              <Box sx={{ display: 'flex', gap: 2, flexWrap: 'wrap' }}>
                <Button variant="outlined" size="small">
                  Test Audio
                </Button>
                <Button variant="outlined" size="small">
                  Audio Settings
                </Button>
                <Button variant="outlined" size="small">
                  Save Preset
                </Button>
                <Button variant="outlined" size="small">
                  Load Preset
                </Button>
                <Button variant="outlined" size="small" color="error">
                  Mute All
                </Button>
              </Box>
            </CardContent>
          </Card>
        </Grid>
      </Grid>
    </Box>
  );
};

export default CommentaryControl;