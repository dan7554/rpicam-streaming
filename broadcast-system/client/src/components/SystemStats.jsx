import React, { useState, useEffect } from 'react';
import {
  Grid,
  Paper,
  Typography,
  Box,
  Card,
  CardContent,
  LinearProgress,
  Chip
} from '@mui/material';
import {
  Videocam,
  Stream,
  Memory,
  Speed,
  SignalCellularAlt,
  Timer,
  People,
  Storage
} from '@mui/icons-material';

const SystemStats = ({ stats, socket }) => {
  const [realtimeStats, setRealtimeStats] = useState(stats);

  useEffect(() => {
    setRealtimeStats(stats);
  }, [stats]);

  useEffect(() => {
    if (socket) {
      socket.on('realtime-stats', (newStats) => {
        if (newStats && typeof newStats === 'object') {
          setRealtimeStats(newStats);
        }
      });
      
      return () => {
        socket.off('realtime-stats');
      };
    }
  }, [socket]);

  const formatUptime = (seconds) => {
    const days = Math.floor(seconds / 86400);
    const hours = Math.floor((seconds % 86400) / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    
    if (days > 0) {
      return `${days}d ${hours}h ${minutes}m`;
    } else if (hours > 0) {
      return `${hours}h ${minutes}m`;
    } else {
      return `${minutes}m`;
    }
  };

  const formatBytes = (bytes) => {
    if (bytes === 0) return '0 B';
    const k = 1024;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
  };

  const getStatusColor = (value, thresholds = { warning: 70, critical: 90 }) => {
    if (value >= thresholds.critical) return 'error';
    if (value >= thresholds.warning) return 'warning';
    return 'success';
  };

  const statsCards = [
    {
      title: 'Cameras',
      icon: <Videocam />,
      value: `${realtimeStats?.cameras?.online || 0}/${realtimeStats?.cameras?.total || 0}`,
      subtitle: 'Online',
      color: realtimeStats?.cameras?.online === realtimeStats?.cameras?.total ? 'success' : 'warning',
      details: [
        { label: 'Total', value: realtimeStats?.cameras?.total || 0 },
        { label: 'Online', value: realtimeStats?.cameras?.online || 0 },
        { label: 'Offline', value: realtimeStats?.cameras?.offline || 0 }
      ]
    },
    {
      title: 'Active Streams',
      icon: <Stream />,
      value: realtimeStats?.streams?.active || 0,
      subtitle: 'Live Streams',
      color: realtimeStats?.streams?.active > 0 ? 'success' : 'default',
      details: [
        { label: 'Active', value: realtimeStats?.streams?.active || 0 },
        { label: 'Total Viewers', value: realtimeStats?.streams?.viewers || 0 },
        { label: 'Data Sent', value: formatBytes(realtimeStats?.streams?.bytesTransferred || 0) }
      ]
    },
    {
      title: 'CPU Usage',
      icon: <Speed />,
      value: `${Math.round(realtimeStats?.system?.cpu || 0)}%`,
      subtitle: 'Processor',
      color: getStatusColor(realtimeStats?.system?.cpu || 0),
      progress: realtimeStats?.system?.cpu || 0,
      details: [
        { label: 'Current', value: `${Math.round(realtimeStats?.system?.cpu || 0)}%` },
        { label: 'Average', value: `${Math.round(realtimeStats?.system?.cpuAverage || 0)}%` },
        { label: 'Cores', value: realtimeStats?.system?.cores || 'N/A' }
      ]
    },
    {
      title: 'Memory Usage',
      icon: <Memory />,
      value: `${Math.round(realtimeStats?.system?.memory || 0)}%`,
      subtitle: 'RAM',
      color: getStatusColor(realtimeStats?.system?.memory || 0),
      progress: realtimeStats?.system?.memory || 0,
      details: [
        { label: 'Used', value: formatBytes(realtimeStats?.system?.memoryUsed || 0) },
        { label: 'Total', value: formatBytes(realtimeStats?.system?.memoryTotal || 0) },
        { label: 'Available', value: formatBytes((realtimeStats?.system?.memoryTotal || 0) - (realtimeStats?.system?.memoryUsed || 0)) }
      ]
    },
    {
      title: 'Network',
      icon: <SignalCellularAlt />,
      value: formatBytes(realtimeStats?.system?.networkOut || 0),
      subtitle: 'Outbound/sec',
      color: 'info',
      details: [
        { label: 'Upload', value: `${formatBytes(realtimeStats?.system?.networkOut || 0)}/s` },
        { label: 'Download', value: `${formatBytes(realtimeStats?.system?.networkIn || 0)}/s` },
        { label: 'Total Out', value: formatBytes(realtimeStats?.system?.totalNetworkOut || 0) }
      ]
    },
    {
      title: 'Uptime',
      icon: <Timer />,
      value: formatUptime(realtimeStats?.system?.uptime || 0),
      subtitle: 'System Running',
      color: 'success',
      details: [
        { label: 'System', value: formatUptime(realtimeStats?.system?.uptime || 0) },
        { label: 'Service', value: formatUptime(realtimeStats?.system?.serviceUptime || 0) },
        { label: 'Started', value: realtimeStats?.system?.startTime ? new Date(realtimeStats.system.startTime).toLocaleString() : 'N/A' }
      ]
    }
  ];

  return (
    <Grid container spacing={2}>
      {statsCards.map((stat, index) => (
        <Grid item xs={12} sm={6} md={4} lg={2} key={index}>
          <Card 
            sx={{ 
              backgroundColor: '#2d2d30',
              border: '1px solid #444',
              height: '100%',
              transition: 'transform 0.2s, border-color 0.2s',
              '&:hover': {
                transform: 'translateY(-2px)',
                borderColor: '#1976d2'
              }
            }}
          >
            <CardContent sx={{ pb: '16px !important' }}>
              <Box sx={{ display: 'flex', alignItems: 'center', mb: 1 }}>
                <Box sx={{ color: '#1976d2', mr: 1 }}>
                  {stat.icon}
                </Box>
                <Typography variant="body2" sx={{ color: '#ccc', fontSize: '0.75rem' }}>
                  {stat.title}
                </Typography>
              </Box>

              <Typography variant="h5" sx={{ color: 'white', fontWeight: 'bold', mb: 0.5 }}>
                {stat.value}
              </Typography>

              <Box sx={{ display: 'flex', alignItems: 'center', mb: 1 }}>
                <Chip 
                  label={stat.subtitle}
                  size="small"
                  color={stat.color}
                  sx={{ fontSize: '0.6rem', height: '20px' }}
                />
              </Box>

              {stat.progress !== undefined && (
                <Box sx={{ mb: 1 }}>
                  <LinearProgress
                    variant="determinate"
                    value={stat.progress}
                    color={stat.color}
                    sx={{ 
                      height: 4,
                      borderRadius: 2,
                      backgroundColor: '#444',
                      '& .MuiLinearProgress-bar': {
                        borderRadius: 2,
                      }
                    }}
                  />
                </Box>
              )}

              <Box sx={{ mt: 1 }}>
                {stat.details.map((detail, detailIndex) => (
                  <Box 
                    key={detailIndex} 
                    sx={{ 
                      display: 'flex', 
                      justifyContent: 'space-between',
                      mb: 0.25
                    }}
                  >
                    <Typography variant="caption" sx={{ color: '#999', fontSize: '0.65rem' }}>
                      {detail.label}:
                    </Typography>
                    <Typography variant="caption" sx={{ color: '#ccc', fontSize: '0.65rem' }}>
                      {detail.value}
                    </Typography>
                  </Box>
                ))}
              </Box>
            </CardContent>
          </Card>
        </Grid>
      ))}

      {/* System Health Overview */}
      <Grid item xs={12}>
        <Paper sx={{ p: 2, backgroundColor: '#1d1d1d', border: '1px solid #333' }}>
          <Typography variant="h6" component="h3" sx={{ color: 'white', mb: 2 }}>
            System Health
          </Typography>
          
          <Grid container spacing={2}>
            <Grid item xs={12} md={4}>
              <Box sx={{ 
                p: 2, 
                backgroundColor: '#2d2d30', 
                borderRadius: 1,
                border: '1px solid #444'
              }}>
                <Typography variant="subtitle2" sx={{ color: 'white', mb: 1 }}>
                  Performance Status
                </Typography>
                <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <Typography variant="body2" sx={{ color: '#ccc' }}>
                      Overall Health
                    </Typography>
                    <Chip 
                      label={
                        (realtimeStats?.system?.cpu || 0) < 80 && 
                        (realtimeStats?.system?.memory || 0) < 80 && 
                        (realtimeStats?.cameras?.online || 0) > 0
                          ? 'Healthy' 
                          : 'Warning'
                      }
                      color={
                        (realtimeStats?.system?.cpu || 0) < 80 && 
                        (realtimeStats?.system?.memory || 0) < 80 && 
                        (realtimeStats?.cameras?.online || 0) > 0
                          ? 'success' 
                          : 'warning'
                      }
                      size="small"
                    />
                  </Box>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <Typography variant="body2" sx={{ color: '#ccc' }}>
                      Encoding Performance
                    </Typography>
                    <Chip 
                      label={
                        (realtimeStats?.streams?.active || 0) > 0 && 
                        (realtimeStats?.system?.cpu || 0) < 90
                          ? 'Good' 
                          : 'Idle'
                      }
                      color={
                        (realtimeStats?.streams?.active || 0) > 0 && 
                        (realtimeStats?.system?.cpu || 0) < 90
                          ? 'success' 
                          : 'default'
                      }
                      size="small"
                    />
                  </Box>
                </Box>
              </Box>
            </Grid>

            <Grid item xs={12} md={4}>
              <Box sx={{ 
                p: 2, 
                backgroundColor: '#2d2d30', 
                borderRadius: 1,
                border: '1px solid #444'
              }}>
                <Typography variant="subtitle2" sx={{ color: 'white', mb: 1 }}>
                  Resource Usage
                </Typography>
                <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
                  <Box>
                    <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
                      <Typography variant="caption" sx={{ color: '#ccc' }}>
                        CPU
                      </Typography>
                      <Typography variant="caption" sx={{ color: '#ccc' }}>
                        {Math.round(realtimeStats?.system?.cpu || 0)}%
                      </Typography>
                    </Box>
                    <LinearProgress
                      variant="determinate"
                      value={realtimeStats?.system?.cpu || 0}
                      color={getStatusColor(realtimeStats?.system?.cpu || 0)}
                      sx={{ 
                        height: 3,
                        borderRadius: 2,
                        backgroundColor: '#444'
                      }}
                    />
                  </Box>
                  <Box>
                    <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
                      <Typography variant="caption" sx={{ color: '#ccc' }}>
                        Memory
                      </Typography>
                      <Typography variant="caption" sx={{ color: '#ccc' }}>
                        {Math.round(realtimeStats?.system?.memory || 0)}%
                      </Typography>
                    </Box>
                    <LinearProgress
                      variant="determinate"
                      value={realtimeStats?.system?.memory || 0}
                      color={getStatusColor(realtimeStats?.system?.memory || 0)}
                      sx={{ 
                        height: 3,
                        borderRadius: 2,
                        backgroundColor: '#444'
                      }}
                    />
                  </Box>
                </Box>
              </Box>
            </Grid>

            <Grid item xs={12} md={4}>
              <Box sx={{ 
                p: 2, 
                backgroundColor: '#2d2d30', 
                borderRadius: 1,
                border: '1px solid #444'
              }}>
                <Typography variant="subtitle2" sx={{ color: 'white', mb: 1 }}>
                  Quick Stats
                </Typography>
                <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between' }}>
                    <Typography variant="caption" sx={{ color: '#ccc' }}>
                      Connected Cameras:
                    </Typography>
                    <Typography variant="caption" sx={{ color: 'white' }}>
                      {realtimeStats?.cameras?.online || 0}
                    </Typography>
                  </Box>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between' }}>
                    <Typography variant="caption" sx={{ color: '#ccc' }}>
                      Active Streams:
                    </Typography>
                    <Typography variant="caption" sx={{ color: 'white' }}>
                      {realtimeStats?.streams?.active || 0}
                    </Typography>
                  </Box>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between' }}>
                    <Typography variant="caption" sx={{ color: '#ccc' }}>
                      Total Viewers:
                    </Typography>
                    <Typography variant="caption" sx={{ color: 'white' }}>
                      {realtimeStats?.streams?.viewers || 0}
                    </Typography>
                  </Box>
                  <Box sx={{ display: 'flex', justifyContent: 'space-between' }}>
                    <Typography variant="caption" sx={{ color: '#ccc' }}>
                      System Uptime:
                    </Typography>
                    <Typography variant="caption" sx={{ color: 'white' }}>
                      {formatUptime(realtimeStats?.system?.uptime || 0)}
                    </Typography>
                  </Box>
                </Box>
              </Box>
            </Grid>
          </Grid>
        </Paper>
      </Grid>
    </Grid>
  );
};

export default SystemStats;