import React from 'react';
import { useLocation, useNavigate } from 'react-router-dom';
import {
  Drawer,
  List,
  ListItemButton,
  ListItemIcon,
  ListItemText,
  Toolbar,
  Typography,
  Box,
  Chip,
  Divider
} from '@mui/material';
import {
  Dashboard,
  Videocam,
  Theaters,
  Stream,
  Mic,
  Preview,
  Settings,
  SignalWifi0Bar,
  SignalWifi4Bar
} from '@mui/icons-material';
import { useBroadcastStore } from '../store/broadcastStore';

const drawerWidth = 240;

const Navigation = () => {
  const navigate = useNavigate();
  const location = useLocation();
  const { connected, systemStatus } = useBroadcastStore();

  // Safely access systemStatus with defaults
  const safeSystemStatus = {
    cameras: { online: 0, total: 0, offline: 0, ...systemStatus?.cameras },
    streams: { active: 0, viewers: 0, ...systemStatus?.streams },
    system: { cpu: 0, memory: 0, uptime: 0, ...systemStatus?.system }
  };

  const menuItems = [
    {
      text: 'Dashboard',
      icon: <Dashboard />,
      path: '/dashboard',
    },
    {
      text: 'Cameras',
      icon: <Videocam />,
      path: '/cameras',
      badge: safeSystemStatus.cameras.online > 0 ? safeSystemStatus.cameras.online : null,
    },
    {
      text: 'Scenes',
      icon: <Theaters />,
      path: '/scenes',
    },
    {
      text: 'Streaming',
      icon: <Stream />,
      path: '/streaming',
      badge: safeSystemStatus.streams.active > 0 ? safeSystemStatus.streams.active : null,
    },
    {
      text: 'Commentary',
      icon: <Mic />,
      path: '/commentary',
    },
    {
      text: 'Live Preview',
      icon: <Preview />,
      path: '/preview',
    },
  ];

  const settingsItems = [
    {
      text: 'Settings',
      icon: <Settings />,
      path: '/settings',
    },
  ];

  const handleNavigation = (path) => {
    navigate(path);
  };

  return (
    <Drawer
      variant="permanent"
      sx={{
        width: drawerWidth,
        flexShrink: 0,
        '& .MuiDrawer-paper': {
          width: drawerWidth,
          boxSizing: 'border-box',
          backgroundColor: '#1a1a1a',
          borderRight: '1px solid #333',
        },
      }}
    >
      <Toolbar>
        <Box sx={{ display: 'flex', alignItems: 'center', width: '100%' }}>
          <Typography variant="h6" component="div" sx={{ flexGrow: 1, color: 'white' }}>
            Broadcast
          </Typography>
          <Chip
            icon={connected ? <SignalWifi4Bar /> : <SignalWifi0Bar />}
            label={connected ? 'Live' : 'Offline'}
            color={connected ? 'success' : 'error'}
            size="small"
            sx={{ 
              fontSize: '0.7rem',
              height: '24px',
              '& .MuiChip-icon': {
                fontSize: '16px'
              }
            }}
          />
        </Box>
      </Toolbar>
      
      <Divider sx={{ borderColor: '#333' }} />
      
      <List sx={{ px: 1, pt: 1 }}>
        {menuItems.map((item) => (
          <ListItemButton
            key={item.text}
            selected={location.pathname === item.path}
            onClick={() => handleNavigation(item.path)}
            sx={{
              borderRadius: 1,
              mb: 0.5,
              '&.Mui-selected': {
                backgroundColor: '#1976d2',
                '&:hover': {
                  backgroundColor: '#1565c0',
                },
              },
              '&:hover': {
                backgroundColor: 'rgba(255, 255, 255, 0.08)',
              },
            }}
          >
            <ListItemIcon sx={{ color: 'inherit', minWidth: 40 }}>
              {item.icon}
            </ListItemIcon>
            <ListItemText 
              primary={item.text}
              primaryTypographyProps={{
                fontSize: '0.875rem',
                fontWeight: location.pathname === item.path ? 600 : 400,
              }}
            />
            {item.badge && (
              <Chip
                label={item.badge}
                size="small"
                color="primary"
                sx={{
                  height: '20px',
                  fontSize: '0.7rem',
                  minWidth: '20px',
                  '& .MuiChip-label': {
                    px: '6px',
                  },
                }}
              />
            )}
          </ListItemButton>
        ))}
      </List>

      <Box sx={{ flexGrow: 1 }} />

      <Divider sx={{ borderColor: '#333', mx: 1 }} />
      
      <List sx={{ px: 1, pb: 2 }}>
        {settingsItems.map((item) => (
          <ListItemButton
            key={item.text}
            selected={location.pathname === item.path}
            onClick={() => handleNavigation(item.path)}
            sx={{
              borderRadius: 1,
              mt: 0.5,
              '&.Mui-selected': {
                backgroundColor: '#1976d2',
                '&:hover': {
                  backgroundColor: '#1565c0',
                },
              },
              '&:hover': {
                backgroundColor: 'rgba(255, 255, 255, 0.08)',
              },
            }}
          >
            <ListItemIcon sx={{ color: 'inherit', minWidth: 40 }}>
              {item.icon}
            </ListItemIcon>
            <ListItemText 
              primary={item.text}
              primaryTypographyProps={{
                fontSize: '0.875rem',
                fontWeight: location.pathname === item.path ? 600 : 400,
              }}
            />
          </ListItemButton>
        ))}
      </List>

      {/* System Status Footer */}
      <Box sx={{ p: 2, backgroundColor: '#111' }}>
        <Typography variant="caption" sx={{ color: '#666', display: 'block', mb: 1 }}>
          System Status
        </Typography>
        <Box sx={{ display: 'flex', justifyContent: 'space-between', mb: 0.5 }}>
          <Typography variant="caption" sx={{ color: '#ccc' }}>
            CPU:
          </Typography>
          <Typography variant="caption" sx={{ color: 'white' }}>
            {Math.round(safeSystemStatus.system.cpu)}%
          </Typography>
        </Box>
        <Box sx={{ display: 'flex', justifyContent: 'space-between' }}>
          <Typography variant="caption" sx={{ color: '#ccc' }}>
            Memory:
          </Typography>
          <Typography variant="caption" sx={{ color: 'white' }}>
            {Math.round(safeSystemStatus.system.memory)}%
          </Typography>
        </Box>
      </Box>
    </Drawer>
  );
};

export default Navigation;