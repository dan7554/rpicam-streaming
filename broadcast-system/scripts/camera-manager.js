#!/usr/bin/env node

/**
 * Camera Management Utility
 * Manage camera connections and test camera availability
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const https = require('https');

const configDir = path.join(__dirname, '../config');
const camerasConfigPath = path.join(configDir, 'cameras.json');

class CameraManager {
  constructor() {
    this.camerasConfig = this.loadCamerasConfig();
  }

  loadCamerasConfig() {
    try {
      return JSON.parse(fs.readFileSync(camerasConfigPath, 'utf8'));
    } catch (error) {
      console.error('❌ Error loading cameras config:', error.message);
      return { cameras: [] };
    }
  }

  saveCamerasConfig() {
    try {
      fs.writeFileSync(camerasConfigPath, JSON.stringify(this.camerasConfig, null, 2));
      console.log('✅ Camera configuration saved');
    } catch (error) {
      console.error('❌ Error saving cameras config:', error.message);
    }
  }

  listCameras() {
    console.log('📹 Available Cameras:');
    console.log('=====================\n');

    if (this.camerasConfig.cameras.length === 0) {
      console.log('No cameras configured.');
      return;
    }

    this.camerasConfig.cameras.forEach((camera, index) => {
      const status = camera.enabled ? '🟢 ENABLED' : '🔴 DISABLED';
      console.log(`${index + 1}. ${camera.name} (${camera.id})`);
      console.log(`   Status: ${status}`);
      console.log(`   Type: ${camera.type.toUpperCase()}`);
      console.log(`   RTSP: ${camera.rtspUrl}`);
      console.log(`   WebRTC: ${camera.url}`);
      if (camera.piConfig) {
        console.log(`   Pi IP: ${camera.piConfig.ipAddress}`);
      }
      console.log('');
    });
  }

  enableCamera(cameraId) {
    const camera = this.camerasConfig.cameras.find(c => c.id === cameraId);
    if (!camera) {
      console.error(`❌ Camera '${cameraId}' not found`);
      return;
    }

    camera.enabled = true;
    this.saveCamerasConfig();
    console.log(`✅ Camera '${camera.name}' enabled`);
  }

  disableCamera(cameraId) {
    const camera = this.camerasConfig.cameras.find(c => c.id === cameraId);
    if (!camera) {
      console.error(`❌ Camera '${cameraId}' not found`);
      return;
    }

    camera.enabled = false;
    this.saveCamerasConfig();
    console.log(`🔴 Camera '${camera.name}' disabled`);
  }

  async testCamera(cameraId) {
    const camera = this.camerasConfig.cameras.find(c => c.id === cameraId);
    if (!camera) {
      console.error(`❌ Camera '${cameraId}' not found`);
      return;
    }

    console.log(`🔍 Testing camera: ${camera.name}`);
    console.log(`   RTSP URL: ${camera.rtspUrl}`);
    console.log(`   WebRTC URL: ${camera.url}`);

    // Test RTSP endpoint (basic TCP connection test)
    const rtspUrl = new URL(camera.rtspUrl);
    await this.testConnection(rtspUrl.hostname, rtspUrl.port || 8554, 'RTSP');

    // Test WebRTC/HTTP endpoint
    const webrtcUrl = new URL(camera.url);
    await this.testHttpEndpoint(camera.url, 'WebRTC');
  }

  async testConnection(hostname, port, type) {
    return new Promise((resolve) => {
      const net = require('net');
      const socket = new net.Socket();
      
      const timeout = setTimeout(() => {
        socket.destroy();
        console.log(`   ❌ ${type} connection timeout (${hostname}:${port})`);
        resolve(false);
      }, 5000);

      socket.connect(port, hostname, () => {
        clearTimeout(timeout);
        socket.destroy();
        console.log(`   ✅ ${type} connection successful (${hostname}:${port})`);
        resolve(true);
      });

      socket.on('error', (error) => {
        clearTimeout(timeout);
        console.log(`   ❌ ${type} connection failed: ${error.message}`);
        resolve(false);
      });
    });
  }

  async testHttpEndpoint(url, type) {
    return new Promise((resolve) => {
      const urlObj = new URL(url);
      const client = urlObj.protocol === 'https:' ? https : http;
      
      const req = client.get(url, (res) => {
        console.log(`   ✅ ${type} HTTP endpoint responding (${res.statusCode})`);
        resolve(true);
      });

      req.on('error', (error) => {
        console.log(`   ❌ ${type} HTTP endpoint failed: ${error.message}`);
        resolve(false);
      });

      req.setTimeout(5000, () => {
        req.destroy();
        console.log(`   ❌ ${type} HTTP endpoint timeout`);
        resolve(false);
      });
    });
  }

  async testAllCameras() {
    console.log('🧪 Testing all enabled cameras...\n');
    
    const enabledCameras = this.camerasConfig.cameras.filter(c => c.enabled);
    
    if (enabledCameras.length === 0) {
      console.log('No enabled cameras to test.');
      return;
    }

    for (const camera of enabledCameras) {
      await this.testCamera(camera.id);
      console.log('');
    }
  }

  generateStreamCommand(cameraId) {
    const camera = this.camerasConfig.cameras.find(c => c.id === cameraId);
    if (!camera || !camera.piConfig) {
      console.error(`❌ Camera '${cameraId}' not found or missing Pi configuration`);
      return;
    }

    const { ipAddress, streamPath, streamingToLocal } = camera.piConfig;
    const { resolution, framerate, bitrate } = camera.settings;
    const [width, height] = resolution.split('x');

    console.log(`🎬 Stream command for ${camera.name}:`);
    console.log('=====================================');
    console.log('');

    if (streamingToLocal) {
      console.log('This Pi streams to your LOCAL MediaMTX server.');
      console.log('Run this command ON YOUR RASPBERRY PI:');
      console.log('');
      console.log(`# Update MEDIAMTX_SERVER IP to your computer's IP`);
      console.log(`MEDIAMTX_SERVER="YOUR_COMPUTER_IP"`);
      console.log('');
      console.log(`rpicam-vid -t 0 --camera 0 --nopreview \\`);
      console.log(`  --codec yuv420 --width ${width} --height ${height} \\`);
      console.log(`  --framerate ${framerate} --inline -o - | \\`);
      console.log(`ffmpeg -f rawvideo -pix_fmt yuv420p \\`);
      console.log(`  -s:v ${width}x${height} -r ${framerate} -i - \\`);
      console.log(`  -c:v libx264 -preset veryfast -tune zerolatency \\`);
      console.log(`  -b:v ${bitrate}000 -f rtsp -rtsp_transport tcp \\`);
      console.log(`  rtsp://\$MEDIAMTX_SERVER:8554/${streamPath}`);
      console.log('');
      console.log('Or copy the prepared script to your Pi:');
      console.log('  scp rpicam-stream-to-remote.sh pi@' + ipAddress + ':~/');
      console.log('  ssh pi@' + ipAddress);
      console.log('  chmod +x rpicam-stream-to-remote.sh');
      console.log('  # Edit the script to set your computer\'s IP');
      console.log('  ./rpicam-stream-to-remote.sh');
    } else {
      console.log('Run this command on your Raspberry Pi:');
      console.log('');
      console.log(`rpicam-vid -t 0 --camera 0 --nopreview \\`);
      console.log(`  --codec yuv420 --width ${width} --height ${height} \\`);
      console.log(`  --framerate ${framerate} --inline -o - | \\`);
      console.log(`ffmpeg -f rawvideo -pix_fmt yuv420p \\`);
      console.log(`  -s:v ${width}x${height} -r ${framerate} -i - \\`);
      console.log(`  -c:v libx264 -preset veryfast -tune zerolatency \\`);
      console.log(`  -f rtsp -rtsp_transport tcp \\`);
      console.log(`  rtsp://localhost:8554/${streamPath}`);
    }
  }
}

// CLI Interface
function showHelp() {
  console.log('📹 Camera Management Utility');
  console.log('============================\n');
  console.log('Usage: node camera-manager.js <command> [options]\n');
  console.log('Commands:');
  console.log('  list                    List all cameras');
  console.log('  enable <camera-id>      Enable a camera');
  console.log('  disable <camera-id>     Disable a camera');
  console.log('  test <camera-id>        Test camera connection');
  console.log('  test-all                Test all enabled cameras');
  console.log('  stream <camera-id>      Show stream command for camera');
  console.log('  help                    Show this help');
  console.log('');
  console.log('Examples:');
  console.log('  node camera-manager.js list');
  console.log('  node camera-manager.js enable rpicam-remote');
  console.log('  node camera-manager.js test rpicam-local');
  console.log('  node camera-manager.js stream rpicam-192-168-1-100');
}

async function main() {
  const manager = new CameraManager();
  const command = process.argv[2];
  const arg = process.argv[3];

  switch (command) {
    case 'list':
      manager.listCameras();
      break;
    case 'enable':
      if (!arg) {
        console.error('❌ Please provide a camera ID');
        process.exit(1);
      }
      manager.enableCamera(arg);
      break;
    case 'disable':
      if (!arg) {
        console.error('❌ Please provide a camera ID');
        process.exit(1);
      }
      manager.disableCamera(arg);
      break;
    case 'test':
      if (!arg) {
        console.error('❌ Please provide a camera ID');
        process.exit(1);
      }
      await manager.testCamera(arg);
      break;
    case 'test-all':
      await manager.testAllCameras();
      break;
    case 'stream':
      if (!arg) {
        console.error('❌ Please provide a camera ID');
        process.exit(1);
      }
      manager.generateStreamCommand(arg);
      break;
    case 'help':
    default:
      showHelp();
      break;
  }
}

if (require.main === module) {
  main().catch(console.error);
}

module.exports = CameraManager;