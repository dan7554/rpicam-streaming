import React, { useRef, useEffect, useState } from 'react';

const WebRTCPreview = ({ url }) => {
  // // console.log('WebRTCPreview','🎬 Initializing WebRTCPreview with URL:', url);;

  const videoRef = useRef(null);
  const pcRef = useRef(null);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState(null);

  useEffect(() => {
    if (!url) return;

    let isActive = true;
    let pc = null;

    const connect = async () => {
      try {
        // console.log('WebRTCPreview','🚀 Starting WebRTC connection to:', url);
        setIsLoading(true);
        setError(null);

        // Clean up existing connection
        if (pcRef.current) {
          // console.log('WebRTCPreview','🧹 Cleaning up existing peer connection');
          pcRef.current.close();
          pcRef.current = null;
        }

        // Create WHEP URL
        const whepUrl = url.endsWith('/') ? url + 'whep' : url + '/whep';
        // console.log('WebRTCPreview','🔗 WHEP URL:', whepUrl);

        // Create peer connection
        // console.log('WebRTCPreview','🌐 Creating RTCPeerConnection');
        pc = new RTCPeerConnection({
          iceServers: [{ urls: 'stun:stun.l.google.com:19302' }],
          iceCandidatePoolSize: 10
        });
        pcRef.current = pc;

        // Add connection state logging
        pc.onconnectionstatechange = () => {
          // console.log('WebRTCPreview','📡 Connection state:', pc.connectionState);
        };

        pc.oniceconnectionstatechange = () => {
          // console.log('WebRTCPreview','🧊 ICE connection state:', pc.iceConnectionState);
        };

        pc.onicegatheringstatechange = () => {
          // console.log('WebRTCPreview','🔍 ICE gathering state:', pc.iceGatheringState);
        };

        // Handle incoming video stream
        pc.ontrack = (event) => {
          // console.log('WebRTCPreview','📺 Received track:', event.track.kind, event.track.id);
          if (event.track.kind === 'video') {
            setIsLoading(false);

            // console.log('WebRTCPreview','✅ Setting video stream to video element', videoRef.current);
            if (videoRef.current) {
              videoRef.current.srcObject = new MediaStream([event.track]);
            } else {
              console.warn('WebRTCPreview', '⚠️ Video element not ready, will retry...');
              // Retry after a short delay
              setTimeout(() => {
                if (videoRef.current) {
                  videoRef.current.srcObject = new MediaStream([event.track]);
                }
              }, 100);
            }
          }
        };

        // Create and send offer
        // console.log('WebRTCPreview','📝 Creating WebRTC offer');
        const offer = await pc.createOffer({
          offerToReceiveVideo: true,
          offerToReceiveAudio: true
        });
        // console.log('WebRTCPreview','🔧 Setting local description');
        await pc.setLocalDescription(offer);
        // console.log('WebRTCPreview','📤 SDP offer created, length:', offer.sdp.length);

        // Check if our offer has ICE credentials
        const offerHasIceUfrag = offer.sdp.includes('a=ice-ufrag:');
        const offerHasIcePwd = offer.sdp.includes('a=ice-pwd:');
        // console.log('WebRTCPreview','🔍 Our offer validation - ice-ufrag:', offerHasIceUfrag, 'ice-pwd:', offerHasIcePwd);
        // console.log('WebRTCPreview','📋 SDP offer:', offer.sdp);

        // console.log('WebRTCPreview','🌐 Sending POST request to WHEP endpoint:', whepUrl);
        const response = await fetch(whepUrl, {
          method: 'POST',
          headers: { 'Content-Type': 'application/sdp' },
          body: offer.sdp
        });

        // console.log('WebRTCPreview','📨 WHEP response status:', response.status, response.statusText);
        if (!response.ok) {
          const errorText = await response.text();
          console.error('❌ WHEP request failed:', errorText);
          throw new Error(`Connection failed: ${response.status} ${response.statusText}`);
        }

        const answer = await response.text();
        // console.log('WebRTCPreview','📥 Received SDP answer, length:', answer.length);
        //  // console.log('WebRTCPreview','� Full SDP answer:', answer);

        // Validate SDP answer has ICE credentials
        const hasIceUfrag = answer.includes('a=ice-ufrag:');
        const hasIcePwd = answer.includes('a=ice-pwd:');
        // console.log('WebRTCPreview','🔍 SDP validation - ice-ufrag:', hasIceUfrag, 'ice-pwd:', hasIcePwd);

        if (!hasIceUfrag || !hasIcePwd) {
          throw new Error('Invalid SDP answer: Missing ICE credentials (ice-ufrag or ice-pwd)');
        }

        // Check if connection is still active before setting remote description
        if (!isActive || !pc || pc.signalingState === 'closed') {
          console.warn('WebRTCPreview', '⚠️ Connection closed before completing setup');
          return;
        }

        // console.log('WebRTCPreview','🔧 Setting remote description');
        await pc.setRemoteDescription({ type: 'answer', sdp: answer });
        // console.log('WebRTCPreview','✅ WebRTC setup complete, waiting for tracks...');

      } catch (err) {
        console.error('💥 WebRTC connection error:', err);
        setError(err.message);
        setIsLoading(false);
      }
    };

    connect();

    return () => {
      isActive = false;
      if (pcRef.current) {
        pcRef.current.close();
        pcRef.current = null;
      }
    };
  }, [url]);

  if (error) {
    return <div style={{ padding: '20px', color: 'red' }}>Error: {error}</div>;
  }

  if (isLoading) {
    return <div style={{ padding: '20px' }}>Connecting...</div>;
  }

  return (
    <video
      ref={videoRef}
      autoPlay
      muted
      playsInline
      style={{ width: '100%', height: '100%', objectFit: 'cover' }}
    />
  );
};

export default WebRTCPreview;