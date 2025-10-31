import React, { useState } from 'react';
import {
  Box,
  Paper,
  Typography,
  Grid,
  Card,
  CardContent,
  Switch,
  FormControlLabel,
  TextField,
  Button,
  Divider,
  Alert,
  Tabs,
  Tab,
  Select,
  MenuItem,
  FormControl,
  InputLabel
} from '@mui/material';
import {
  Save,
  Restore,
  Download,
  Upload,
  RestartAlt
} from '@mui/icons-material';

const TabPanel = ({ children, value, index, ...other }) => {
  return (
    <div
      role="tabpanel"
      hidden={value !== index}
      id={`settings-tabpanel-${index}`}
      aria-labelledby={`settings-tab-${index}`}
      {...other}
    >
      {value === index && (
        <Box sx={{ p: 3 }}>
          {children}
        </Box>
      )}
    </div>
  );
};

const Settings = () => {
  const [tabValue, setTabValue] = useState(0);
  const [settings, setSettings] = useState({
    // General Settings
    autoSave: true,
    autoReconnect: true,
    debugMode: false,
    maxRetries: 3,
    
    // Video Settings
    defaultResolution: '1920x1080',
    defaultFramerate: 30,
    defaultBitrate: 4000,
    hardwareAcceleration: true,
    
    // Audio Settings
    audioSampleRate: 48000,
    audioBitrate: 128,
    audioChannels: 2,
    echoCancellation: true,
    noiseSuppression: true,
    
    // Stream Settings
    streamDelay: 2,
    keyFrameInterval: 2,
    bFrames: 2,
    
    // Server Settings
    serverHost: 'localhost',
    serverPort: 3001,
    apiTimeout: 30000,
    websocketTimeout: 20000,
  });

  const [saveStatus, setSaveStatus] = useState(null);

  const handleTabChange = (event, newValue) => {
    setTabValue(newValue);
  };

  const handleSettingChange = (key, value) => {
    setSettings(prev => ({
      ...prev,
      [key]: value
    }));
  };

  const handleSaveSettings = async () => {
    try {
      // TODO: Implement API call to save settings
      setSaveStatus({ type: 'success', message: 'Settings saved successfully!' });
      setTimeout(() => setSaveStatus(null), 3000);
    } catch (error) {
      setSaveStatus({ type: 'error', message: 'Failed to save settings: ' + error.message });
      setTimeout(() => setSaveStatus(null), 5000);
    }
  };

  const handleResetSettings = () => {
    if (window.confirm('Are you sure you want to reset all settings to defaults?')) {
      // Reset to default values
      setSettings({
        autoSave: true,
        autoReconnect: true,
        debugMode: false,
        maxRetries: 3,
        defaultResolution: '1920x1080',
        defaultFramerate: 30,
        defaultBitrate: 4000,
        hardwareAcceleration: true,
        audioSampleRate: 48000,
        audioBitrate: 128,
        audioChannels: 2,
        echoCancellation: true,
        noiseSuppression: true,
        streamDelay: 2,
        keyFrameInterval: 2,
        bFrames: 2,
        serverHost: 'localhost',
        serverPort: 3001,
        apiTimeout: 30000,
        websocketTimeout: 20000,
      });
      setSaveStatus({ type: 'info', message: 'Settings reset to defaults' });
      setTimeout(() => setSaveStatus(null), 3000);
    }
  };

  const handleExportSettings = () => {
    const dataStr = "data:text/json;charset=utf-8," + encodeURIComponent(JSON.stringify(settings, null, 2));
    const downloadAnchorNode = document.createElement('a');
    downloadAnchorNode.setAttribute("href", dataStr);
    downloadAnchorNode.setAttribute("download", "broadcast-settings.json");
    document.body.appendChild(downloadAnchorNode);
    downloadAnchorNode.click();
    downloadAnchorNode.remove();
  };

  const handleImportSettings = (event) => {
    const file = event.target.files[0];
    if (file) {
      const reader = new FileReader();
      reader.onload = (e) => {
        try {
          const importedSettings = JSON.parse(e.target.result);
          setSettings(importedSettings);
          setSaveStatus({ type: 'success', message: 'Settings imported successfully!' });
          setTimeout(() => setSaveStatus(null), 3000);
        } catch (error) {
          setSaveStatus({ type: 'error', message: 'Failed to import settings: Invalid file format' });
          setTimeout(() => setSaveStatus(null), 5000);
        }
      };
      reader.readAsText(file);
    }
  };

  return (
    <Box sx={{ p: 3 }}>
      <Typography variant="h4" component="h1" gutterBottom sx={{ color: 'white', mb: 3 }}>
        Settings
      </Typography>

      {saveStatus && (
        <Alert severity={saveStatus.type} sx={{ mb: 3 }}>
          {saveStatus.message}
        </Alert>
      )}

      <Paper sx={{ backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
        <Tabs 
          value={tabValue} 
          onChange={handleTabChange}
          sx={{ 
            borderBottom: '1px solid #333',
            '& .MuiTab-root': { color: '#ccc' },
            '& .Mui-selected': { color: 'white' }
          }}
        >
          <Tab label="General" />
          <Tab label="Video" />
          <Tab label="Audio" />
          <Tab label="Streaming" />
          <Tab label="Server" />
        </Tabs>

        <TabPanel value={tabValue} index={0}>
          <Typography variant="h6" sx={{ color: 'white', mb: 3 }}>
            General Settings
          </Typography>
          <Grid container spacing={3}>
            <Grid item xs={12} sm={6}>
              <FormControlLabel
                control={
                  <Switch
                    checked={settings.autoSave}
                    onChange={(e) => handleSettingChange('autoSave', e.target.checked)}
                    color="primary"
                  />
                }
                label="Auto-save settings"
                sx={{ color: 'white' }}
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <FormControlLabel
                control={
                  <Switch
                    checked={settings.autoReconnect}
                    onChange={(e) => handleSettingChange('autoReconnect', e.target.checked)}
                    color="primary"
                  />
                }
                label="Auto-reconnect on disconnect"
                sx={{ color: 'white' }}
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <FormControlLabel
                control={
                  <Switch
                    checked={settings.debugMode}
                    onChange={(e) => handleSettingChange('debugMode', e.target.checked)}
                    color="primary"
                  />
                }
                label="Debug mode"
                sx={{ color: 'white' }}
              />
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Max Retry Attempts"
                type="number"
                value={settings.maxRetries}
                onChange={(e) => handleSettingChange('maxRetries', parseInt(e.target.value))}
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
        </TabPanel>

        <TabPanel value={tabValue} index={1}>
          <Typography variant="h6" sx={{ color: 'white', mb: 3 }}>
            Video Settings
          </Typography>
          <Grid container spacing={3}>
            <Grid item xs={12} sm={6}>
              <FormControl fullWidth>
                <InputLabel sx={{ color: '#ccc' }}>Default Resolution</InputLabel>
                <Select
                  value={settings.defaultResolution}
                  onChange={(e) => handleSettingChange('defaultResolution', e.target.value)}
                  sx={{
                    color: 'white',
                    '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                    '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                    '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
                  }}
                >
                  <MenuItem value="1920x1080">1080p (1920x1080)</MenuItem>
                  <MenuItem value="1280x720">720p (1280x720)</MenuItem>
                  <MenuItem value="854x480">480p (854x480)</MenuItem>
                  <MenuItem value="640x360">360p (640x360)</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Default Frame Rate"
                type="number"
                value={settings.defaultFramerate}
                onChange={(e) => handleSettingChange('defaultFramerate', parseInt(e.target.value))}
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
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Default Bitrate (kbps)"
                type="number"
                value={settings.defaultBitrate}
                onChange={(e) => handleSettingChange('defaultBitrate', parseInt(e.target.value))}
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
            <Grid item xs={12} sm={6}>
              <FormControlLabel
                control={
                  <Switch
                    checked={settings.hardwareAcceleration}
                    onChange={(e) => handleSettingChange('hardwareAcceleration', e.target.checked)}
                    color="primary"
                  />
                }
                label="Hardware Acceleration"
                sx={{ color: 'white' }}
              />
            </Grid>
          </Grid>
        </TabPanel>

        <TabPanel value={tabValue} index={2}>
          <Typography variant="h6" sx={{ color: 'white', mb: 3 }}>
            Audio Settings
          </Typography>
          <Grid container spacing={3}>
            <Grid item xs={12} sm={6}>
              <FormControl fullWidth>
                <InputLabel sx={{ color: '#ccc' }}>Sample Rate</InputLabel>
                <Select
                  value={settings.audioSampleRate}
                  onChange={(e) => handleSettingChange('audioSampleRate', e.target.value)}
                  sx={{
                    color: 'white',
                    '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                    '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                    '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
                  }}
                >
                  <MenuItem value={48000}>48 kHz</MenuItem>
                  <MenuItem value={44100}>44.1 kHz</MenuItem>
                  <MenuItem value={22050}>22.05 kHz</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Audio Bitrate (kbps)"
                type="number"
                value={settings.audioBitrate}
                onChange={(e) => handleSettingChange('audioBitrate', parseInt(e.target.value))}
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
            <Grid item xs={12} sm={6}>
              <FormControl fullWidth>
                <InputLabel sx={{ color: '#ccc' }}>Audio Channels</InputLabel>
                <Select
                  value={settings.audioChannels}
                  onChange={(e) => handleSettingChange('audioChannels', e.target.value)}
                  sx={{
                    color: 'white',
                    '& .MuiOutlinedInput-notchedOutline': { borderColor: '#555' },
                    '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: '#777' },
                    '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: '#1976d2' }
                  }}
                >
                  <MenuItem value={1}>Mono</MenuItem>
                  <MenuItem value={2}>Stereo</MenuItem>
                </Select>
              </FormControl>
            </Grid>
            <Grid item xs={12} sm={6}>
              <FormControlLabel
                control={
                  <Switch
                    checked={settings.echoCancellation}
                    onChange={(e) => handleSettingChange('echoCancellation', e.target.checked)}
                    color="primary"
                  />
                }
                label="Echo Cancellation"
                sx={{ color: 'white' }}
              />
            </Grid>
            <Grid item xs={12}>
              <FormControlLabel
                control={
                  <Switch
                    checked={settings.noiseSuppression}
                    onChange={(e) => handleSettingChange('noiseSuppression', e.target.checked)}
                    color="primary"
                  />
                }
                label="Noise Suppression"
                sx={{ color: 'white' }}
              />
            </Grid>
          </Grid>
        </TabPanel>

        <TabPanel value={tabValue} index={3}>
          <Typography variant="h6" sx={{ color: 'white', mb: 3 }}>
            Streaming Settings
          </Typography>
          <Grid container spacing={3}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Stream Delay (seconds)"
                type="number"
                value={settings.streamDelay}
                onChange={(e) => handleSettingChange('streamDelay', parseInt(e.target.value))}
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
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Key Frame Interval"
                type="number"
                value={settings.keyFrameInterval}
                onChange={(e) => handleSettingChange('keyFrameInterval', parseInt(e.target.value))}
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
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="B-Frames"
                type="number"
                value={settings.bFrames}
                onChange={(e) => handleSettingChange('bFrames', parseInt(e.target.value))}
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
        </TabPanel>

        <TabPanel value={tabValue} index={4}>
          <Typography variant="h6" sx={{ color: 'white', mb: 3 }}>
            Server Settings
          </Typography>
          <Grid container spacing={3}>
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Server Host"
                value={settings.serverHost}
                onChange={(e) => handleSettingChange('serverHost', e.target.value)}
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
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="Server Port"
                type="number"
                value={settings.serverPort}
                onChange={(e) => handleSettingChange('serverPort', parseInt(e.target.value))}
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
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="API Timeout (ms)"
                type="number"
                value={settings.apiTimeout}
                onChange={(e) => handleSettingChange('apiTimeout', parseInt(e.target.value))}
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
            <Grid item xs={12} sm={6}>
              <TextField
                fullWidth
                label="WebSocket Timeout (ms)"
                type="number"
                value={settings.websocketTimeout}
                onChange={(e) => handleSettingChange('websocketTimeout', parseInt(e.target.value))}
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
        </TabPanel>

        <Divider sx={{ borderColor: '#333' }} />
        
        <Box sx={{ p: 3, display: 'flex', gap: 2, flexWrap: 'wrap' }}>
          <Button
            variant="contained"
            startIcon={<Save />}
            onClick={handleSaveSettings}
            color="primary"
          >
            Save Settings
          </Button>
          
          <Button
            variant="outlined"
            startIcon={<RestartAlt />}
            onClick={handleResetSettings}
            color="warning"
          >
            Reset to Defaults
          </Button>
          
          <Button
            variant="outlined"
            startIcon={<Download />}
            onClick={handleExportSettings}
          >
            Export Settings
          </Button>
          
          <Button
            variant="outlined"
            component="label"
            startIcon={<Upload />}
          >
            Import Settings
            <input
              type="file"
              accept=".json"
              onChange={handleImportSettings}
              style={{ display: 'none' }}
            />
          </Button>
        </Box>
      </Paper>
    </Box>
  );
};

export default Settings;