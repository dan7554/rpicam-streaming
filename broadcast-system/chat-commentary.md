## 🎙️ **Audio Commentary System Overview**

Your broadcast system includes a comprehensive multi-commentator audio system designed specifically for professional racetrack broadcasting. Here's how it works:

### **🎯 System Architecture**

#### **1. Multi-Commentator Support**
The system supports multiple commentators simultaneously:
- **Main Commentator** - Primary race caller (always enabled)
- **Color Commentator** - Provides analysis and background (push-to-talk)
- **Field Reporter** - Remote reporting from track locations (push-to-talk)

#### **2. Real-Time Audio Processing**
Each commentator gets individual audio processing:
- **Gain Control** - Adjustable input volume per commentator
- **Noise Gate** - Eliminates background noise when not speaking
- **Compression** - Maintains consistent audio levels
- **Echo Cancellation** - Prevents feedback loops
- **Auto Gain Control** - Automatically adjusts levels

### **🔧 How It Works**

#### **Frontend Control Panel** (`CommentaryControl.jsx`)
The web interface provides:

1. **Main Controls**:
   - Toggle commentary system on/off
   - Microphone enable/disable button
   - Push-to-talk mode selection
   - Volume sliders for each commentator

2. **Real-Time Audio Levels**:
   - Visual level meters for input/output
   - Peak level indicators with color coding:
     - 🟢 Green (0-60%): Normal levels
     - 🟡 Orange (60-80%): Moderate levels  
     - 🔴 Red (80%+): High levels/potential clipping

3. **Recording Controls**:
   - Start/stop individual recording sessions
   - Session management and file naming

#### **Backend Audio Management** (`CommentaryManager.js`)
The server handles:

1. **Audio Stream Management**:
   - WebRTC audio input from browser microphones
   - Real-time audio level monitoring
   - Multi-channel audio mixing

2. **Commentator Management**:
   ```javascript
   // Each commentator has individual settings
   {
     id: "main-commentator",
     name: "Main Commentator", 
     enabled: true,
     inputDevice: "default",
     settings: {
       gain: 1.0,
       noiseGate: true,
       compression: true,
       pushToTalk: false,
       autoGainControl: true
     }
   }
   ```

3. **Audio Processing Pipeline**:
   - Input → Noise Gate → Compression → Gain → Echo Cancellation → Mixer

### **🎮 Key Features**

#### **Push-to-Talk System**
- Configurable hotkeys (F1, F2, F3) for each commentator
- Visual indicators show when commentators are "live"
- Automatic muting when push-to-talk is released

#### **Audio Mixing**
The system mixes multiple audio sources:
- **Commentary tracks** (multiple commentators)
- **Ambient track audio** (crowd noise, engines)
- **Background music** (intro/outro music)
- **Race track audio** (PA system, radio communications)

#### **Professional Audio Levels**
- **Sample Rate**: 48kHz (broadcast quality)
- **Bitrate**: 128kbps (high quality for streaming)
- **Format**: Stereo output with individual channel control
- **Latency**: <100ms for real-time mixing

### **🔄 Real-Time Communication Flow**

1. **Client → Server**: 
   ```javascript
   socket.emit('toggle-microphone', true);
   socket.emit('set-commentary-volume', 80);
   socket.emit('start-commentary-recording');
   ```

2. **Server → Client**:
   ```javascript
   socket.emit('commentary-stats', { inputLevel: 65, outputLevel: 72 });
   socket.emit('audio-level', 0.65);
   ```

3. **WebSocket Events**:
   - `commentary-start` / `commentary-stop` - Control commentary sessions
   - `audio-level` - Real-time level updates every 100ms
   - `commentary-stats` - Detailed audio statistics
   - `toggle-microphone` - Mic on/off control

### **📁 Audio File Management**

#### **Recording Sessions**
- Individual recordings per commentator
- Automatic file naming: `commentary_[commentator-id]_[timestamp].wav`
- Session metadata tracking (start/end times, duration)
- WAV format for highest quality

#### **Audio Sources**
The system can integrate multiple audio inputs:
- **Live microphones** (WebRTC from browser)
- **Audio files** (background music, sound effects)
- **Line inputs** (external audio equipment)
- **Track audio** (PA system, radio feeds)

### **🎯 Racetrack-Specific Features**

#### **Multi-Position Commentary**
Perfect for race broadcasting:
- **Turn commentators** at different track locations
- **Pit lane reporters** for driver interviews
- **Start/finish line announcers**
- **Spotter network** integration

#### **Race Event Integration**
- **Pre-race** commentary with background music
- **Live race** commentary with track audio
- **Post-race** interviews and analysis
- **Commercial break** management

### **🚀 Production Integration**

The commentary audio gets mixed into your final broadcast stream that goes to:
- **YouTube Live** via RTMP
- **Facebook Live** 
- **Twitch**
- **Local recording** for later editing

The system is designed to be professional-grade, supporting the complex audio needs of live racetrack broadcasting with multiple commentators, real-time mixing, and broadcast-quality output! 🏁