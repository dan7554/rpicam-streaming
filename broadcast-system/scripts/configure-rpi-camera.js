#!/usr/bin/env node

/**
 * RPi Camera Configuration Helper
 * This script helps configure your Raspberry Pi camera in the broadcast system
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

const configDir = path.join(__dirname, '../config');
const camerasConfigPath = path.join(configDir, 'cameras.json');

async function question(prompt) {
  return new Promise((resolve) => {
    rl.question(prompt, resolve);
  });
}

async function configurePiCamera() {
  console.log('🎥 Raspberry Pi Camera Configuration Helper');
  console.log('===========================================\n');

  try {
    // Read current cameras config
    const camerasConfig = JSON.parse(fs.readFileSync(camerasConfigPath, 'utf8'));

    console.log('Please provide your Raspberry Pi camera details:\n');

    const cameraName = await question('Camera name (e.g., "Pit Lane Camera"): ');
    const piIpAddress = await question('Raspberry Pi IP address (e.g., 192.168.1.100): ');
    const mediaPort = await question('MediaMTX port (default 8554): ') || '8554';
    const webrtcPort = await question('WebRTC port (default 8889): ') || '8889';
    const streamPath = await question('Stream path (default "rpicam"): ') || 'rpicam';
    const resolution = await question('Resolution (default "1920x1080"): ') || '1920x1080';
    const framerate = await question('Frame rate (default 30): ') || '30';
    const bitrate = await question('Bitrate in kbps (default 5000): ') || '5000';

    // Create new camera configuration
    const newCamera = {
      id: `rpicam-${piIpAddress.replace(/\./g, '-')}`,
      name: cameraName,
      type: "webrtc",
      url: `http://${piIpAddress}:${webrtcPort}/${streamPath}/whep`,
      rtspUrl: `rtsp://${piIpAddress}:${mediaPort}/${streamPath}`,
      enabled: true,
      position: {
        x: 0,
        y: 0,
        width: 1920,
        height: 1080
      },
      settings: {
        resolution: resolution,
        framerate: parseInt(framerate),
        bitrate: parseInt(bitrate)
      },
      piConfig: {
        ipAddress: piIpAddress,
        mediaPort: parseInt(mediaPort),
        webrtcPort: parseInt(webrtcPort),
        streamPath: streamPath
      }
    };

    // Add to cameras array
    camerasConfig.cameras.push(newCamera);

    // Write back to file
    fs.writeFileSync(camerasConfigPath, JSON.stringify(camerasConfig, null, 2));

    console.log('\n✅ Camera configuration added successfully!');
    console.log('\nCamera details:');
    console.log(`- ID: ${newCamera.id}`);
    console.log(`- Name: ${newCamera.name}`);
    console.log(`- RTSP URL: ${newCamera.rtspUrl}`);
    console.log(`- WebRTC URL: ${newCamera.url}`);

    console.log('\n📋 Next steps:');
    console.log('1. Make sure your Raspberry Pi is running MediaMTX');
    console.log('2. Ensure rpicam-stream.sh is running on your Pi');
    console.log('3. Restart the broadcast system backend to load the new camera');
    console.log('4. The camera will appear in the admin dashboard');

    console.log('\n🔧 Commands to run on your Raspberry Pi:');
    console.log(`cd /path/to/your/mediamtx && ./run.sh`);
    console.log(`cd /path/to/your/rpicam && ./rpicam-stream.sh`);

  } catch (error) {
    console.error('❌ Error configuring camera:', error.message);
  }

  rl.close();
}

// Check if we're running as a script
if (require.main === module) {
  configurePiCamera().catch(console.error);
}

module.exports = { configurePiCamera };