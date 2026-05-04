#!/usr/bin/env python3
"""
WHIP publisher for Raspberry Pi camera.
Publishes H.264 video from libcamerasrc via WebRTC (WHIP) to MediaMTX.

Uses GStreamer webrtcbin for WebRTC and a simple HTTP POST for WHIP signaling.
This eliminates RTMP/SRT protocol conversion — true end-to-end WebRTC.

Usage:
    python3 whip-publish.py --url http://localhost:8889/cam3/whip
    python3 whip-publish.py --url http://localhost:8889/cam3/whip --width 1920 --height 1080 --bitrate 5500
"""

import argparse
import json
import logging
import os
import signal
import sys
import threading
import time
import urllib.request
import urllib.error

import gi
gi.require_version('Gst', '1.0')
gi.require_version('GstWebRTC', '1.0')
gi.require_version('GstSdp', '1.0')
from gi.repository import Gst, GstWebRTC, GstSdp, GLib

logging.basicConfig(level=logging.INFO, format='%(asctime)s [WHIP] %(message)s')
log = logging.getLogger('whip')

# Globals
pipeline = None
loop = None
whip_url = None
whip_session_url = None
webrtc_element = None


def on_negotiation_needed(webrtcbin):
    """Called when webrtcbin needs to create an offer."""
    log.info("Negotiation needed — creating offer")
    promise = Gst.Promise.new_with_change_func(on_offer_created, webrtcbin)
    webrtcbin.emit('create-offer', None, promise)


def on_offer_created(promise, webrtcbin):
    """Offer created — POST it to WHIP immediately (without candidates).
    Candidates will be trickled via PATCH as they're gathered."""
    global whip_session_url

    reply = promise.get_reply()
    offer = reply.get_value('offer')
    sdp_text = offer.sdp.as_text()
    log.info("Offer created (%d bytes), POSTing to %s", len(sdp_text), whip_url)

    # Set local description — this triggers ICE candidate gathering
    promise_local = Gst.Promise.new()
    webrtcbin.emit('set-local-description', offer, promise_local)
    promise_local.interrupt()

    # POST offer to WHIP endpoint
    try:
        req = urllib.request.Request(
            whip_url,
            data=sdp_text.encode('utf-8'),
            headers={'Content-Type': 'application/sdp'},
            method='POST'
        )
        resp = urllib.request.urlopen(req, timeout=10)
        answer_sdp = resp.read().decode('utf-8')
        status = resp.status

        # Save session URL for cleanup and trickle ICE
        location = resp.headers.get('Location')
        if location:
            if location.startswith('/'):
                from urllib.parse import urlparse
                parsed = urlparse(whip_url)
                whip_session_url = f"{parsed.scheme}://{parsed.netloc}{location}"
            else:
                whip_session_url = location
            log.info("Session URL: %s", whip_session_url)

        log.info("Got answer (HTTP %d, %d bytes)", status, len(answer_sdp))

    except urllib.error.HTTPError as e:
        log.error("WHIP POST failed: HTTP %d %s", e.code, e.reason)
        body = e.read().decode('utf-8', errors='replace')
        log.error("Response body: %s", body[:500])
        GLib.idle_add(loop.quit)
        return
    except Exception as e:
        log.error("WHIP POST failed: %s", e)
        GLib.idle_add(loop.quit)
        return

    # Set remote description (answer)
    res, sdpmsg = GstSdp.SDPMessage.new_from_text(answer_sdp)
    if res != GstSdp.SDPResult.OK:
        log.error("Failed to parse answer SDP")
        GLib.idle_add(loop.quit)
        return

    answer = GstWebRTC.WebRTCSessionDescription.new(
        GstWebRTC.WebRTCSDPType.ANSWER, sdpmsg
    )
    promise_remote = Gst.Promise.new()
    webrtcbin.emit('set-remote-description', answer, promise_remote)
    promise_remote.interrupt()
    log.info("Remote description set — ICE checking will begin as candidates are trickled")


def on_ice_candidate(webrtcbin, mline_index, candidate):
    """ICE candidate gathered — send it to MediaMTX via WHIP trickle ICE PATCH."""
    if not candidate:
        return
    if not whip_session_url:
        log.warning("No session URL for trickle ICE, dropping candidate")
        return

    # Build trickle ICE SDP fragment (RFC 8840)
    # Get the ice-ufrag and ice-pwd from the local description
    local_desc = webrtcbin.get_property('local-description')
    ufrag = ""
    if local_desc:
        sdp_text = local_desc.sdp.as_text()
        for line in sdp_text.split('\n'):
            if line.startswith('a=ice-ufrag:'):
                ufrag = line.split(':')[1].strip()
                break

    frag = (
        f"a=ice-ufrag:{ufrag}\r\n"
        f"a=mid:video0\r\n"
        f"a={candidate}\r\n"
    )

    log.info("Trickle ICE: %s", candidate.split(' ')[4] if len(candidate.split(' ')) > 4 else candidate[:60])
    try:
        req = urllib.request.Request(
            whip_session_url,
            data=frag.encode('utf-8'),
            headers={'Content-Type': 'application/trickle-ice-sdpfrag'},
            method='PATCH'
        )
        resp = urllib.request.urlopen(req, timeout=5)
        resp_body = resp.read().decode('utf-8', errors='replace')
        log.info("  PATCH response: HTTP %d, body: %s", resp.status, resp_body[:200] if resp_body else "(empty)")
    except urllib.error.HTTPError as e:
        log.warning("Trickle PATCH failed: HTTP %d %s", e.code, e.reason)
    except Exception as e:
        log.warning("Trickle PATCH failed: %s", e)


def on_connection_state_changed(webrtcbin, pspec):
    """Monitor WebRTC connection state."""
    state = webrtcbin.get_property('connection-state')
    log.info("Connection state: %s", state.value_nick)
    if state == GstWebRTC.WebRTCPeerConnectionState.FAILED:
        log.error("WebRTC connection failed")
        GLib.idle_add(loop.quit)
    elif state == GstWebRTC.WebRTCPeerConnectionState.CONNECTED:
        log.info("WebRTC media flowing!")


def on_ice_connection_state_changed(webrtcbin, pspec):
    """Monitor ICE connection state."""
    state = webrtcbin.get_property('ice-connection-state')
    log.info("ICE state: %s", state.value_nick)


def on_ice_gathering_state_changed(webrtcbin, pspec):
    """Monitor ICE gathering state."""
    state = webrtcbin.get_property('ice-gathering-state')
    log.info("ICE gathering: %s", state.value_nick)


def build_pipeline(args):
    """Build the GStreamer pipeline for camera → WebRTC."""

    # Pipeline:
    # libcamerasrc → videoconvert → x264enc → rtph264pay → webrtcbin
    #
    # webrtcbin handles DTLS, SRTP, ICE, and sends RTP directly to the peer.
    pipeline_str = (
        f'libcamerasrc ! '
        f'video/x-raw,width={args.width},height={args.height},'
        f'framerate={args.fps}/1,format=NV12 ! '
        f'queue max-size-buffers=1 leaky=downstream ! '
        f'videoconvert ! '
        f'x264enc tune=zerolatency speed-preset=faster '
        f'bitrate={args.bitrate} key-int-max={args.fps} '
        f'bframes=0 threads=4 ! '
        f'video/x-h264,profile=baseline ! '
        f'rtph264pay config-interval=-1 pt=96 ! '
        f'application/x-rtp,media=video,encoding-name=H264,payload=96 ! '
        f'webrtcbin name=webrtc bundle-policy=max-bundle '
        f'stun-server=stun://stun.l.google.com:19302'
    )

    log.info("Pipeline: %s", pipeline_str)
    pipe = Gst.parse_launch(pipeline_str)

    webrtcbin = pipe.get_by_name('webrtc')
    if not webrtcbin:
        log.error("Could not find webrtcbin in pipeline")
        sys.exit(1)

    # Force ICE-TCP if requested (needed when UDP doesn't traverse the network)
    if args.ice_tcp:
        # Disable UDP candidates, only use TCP
        webrtcbin.set_property('ice-transport-policy', 'relay')
        log.info("ICE transport: TCP only (relay)")

    # Connect signals
    webrtcbin.connect('on-negotiation-needed', on_negotiation_needed)
    webrtcbin.connect('on-ice-candidate', on_ice_candidate)
    webrtcbin.connect('notify::connection-state', on_connection_state_changed)
    webrtcbin.connect('notify::ice-connection-state', on_ice_connection_state_changed)
    webrtcbin.connect('notify::ice-gathering-state', on_ice_gathering_state_changed)

    return pipe


def on_bus_message(bus, message):
    """Handle GStreamer bus messages."""
    t = message.type
    if t == Gst.MessageType.EOS:
        log.info("End of stream")
        loop.quit()
    elif t == Gst.MessageType.ERROR:
        err, debug = message.parse_error()
        log.error("Pipeline error: %s (debug: %s)", err.message, debug)
        loop.quit()
    elif t == Gst.MessageType.WARNING:
        err, debug = message.parse_warning()
        log.warning("Pipeline warning: %s", err.message)
    elif t == Gst.MessageType.STATE_CHANGED:
        if message.src == pipeline:
            old, new, pending = message.parse_state_changed()
            if new == Gst.State.PLAYING:
                log.info("Pipeline is PLAYING")
    return True


def cleanup():
    """Clean up WHIP session and pipeline."""
    global whip_session_url
    if whip_session_url:
        try:
            req = urllib.request.Request(whip_session_url, method='DELETE')
            urllib.request.urlopen(req, timeout=5)
            log.info("Deleted WHIP session")
        except Exception:
            pass
    if pipeline:
        pipeline.set_state(Gst.State.NULL)


def main():
    global pipeline, loop, whip_url

    parser = argparse.ArgumentParser(description='WHIP camera publisher')
    parser.add_argument('--url', required=True, help='WHIP endpoint URL')
    parser.add_argument('--width', type=int, default=1920)
    parser.add_argument('--height', type=int, default=1080)
    parser.add_argument('--fps', type=int, default=30)
    parser.add_argument('--bitrate', type=int, default=5500, help='kbps')
    parser.add_argument('--ice-tcp', action='store_true', help='Force ICE TCP')
    parser.add_argument('--retry', action='store_true', help='Auto-retry on failure')
    parser.add_argument('--retry-delay', type=int, default=5, help='Retry delay seconds')
    args = parser.parse_args()

    whip_url = args.url

    Gst.init(None)

    while True:
        log.info("Starting WHIP publish to %s", whip_url)
        log.info("  Resolution: %dx%d@%dfps, bitrate: %dkbps", args.width, args.height, args.fps, args.bitrate)

        pipeline = build_pipeline(args)

        bus = pipeline.get_bus()
        bus.add_signal_watch()
        bus.connect('message', on_bus_message)

        loop = GLib.MainLoop()

        # Handle signals
        def signal_handler(sig, frame):
            log.info("Signal %d received, shutting down", sig)
            GLib.idle_add(loop.quit)

        signal.signal(signal.SIGINT, signal_handler)
        signal.signal(signal.SIGTERM, signal_handler)

        pipeline.set_state(Gst.State.PLAYING)

        try:
            loop.run()
        except Exception as e:
            log.error("Main loop error: %s", e)
        finally:
            cleanup()

        if not args.retry:
            break

        log.info("Retrying in %ds...", args.retry_delay)
        time.sleep(args.retry_delay)


if __name__ == '__main__':
    main()
