#!/usr/bin/env python3
"""
Real-time AI video upscaler using NVIDIA Maxine Video Super Resolution.

Pulls an RTMP stream, upscales 2x with AI on GPU, pushes back as a new stream.
Designed to run on a g4dn.xlarge (Tesla T4) EC2 instance.

Usage:
    python3 upscale-stream.py --input rtmp://mediamtx:1935/cam3 \
                               --output rtmp://mediamtx:1935/cam3-4k \
                               --scale 2
"""

import argparse
import signal
import subprocess
import sys
import time
import numpy as np
import torch
import torch.nn.functional as F
from nvvfx import VideoSuperRes

# Graceful shutdown
shutdown = False
def handle_signal(sig, frame):
    global shutdown
    shutdown = True
    print(f"\n[upscaler] Received signal {sig}, shutting down...")

signal.signal(signal.SIGINT, handle_signal)
signal.signal(signal.SIGTERM, handle_signal)


def create_ffmpeg_reader(input_url, width, height, target_fps=5):
    """FFmpeg process that decodes RTMP to raw RGB frames on stdout.
    Throttles to target_fps to avoid overwhelming the pipeline."""
    cmd = [
        "ffmpeg",
        "-hide_banner", "-loglevel", "warning",
        "-i", input_url,
        "-f", "rawvideo",
        "-pix_fmt", "rgb24",
        "-an", "-sn",
        "-vf", f"scale={width}:{height},fps={target_fps}",
        "pipe:1"
    ]
    return subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def create_ffmpeg_writer(output_url, width, height, fps, bitrate="15000k"):
    """FFmpeg process that encodes YUV420P frames from stdin to RTMP."""
    cmd = [
        "ffmpeg",
        "-hide_banner", "-loglevel", "warning",
        "-f", "rawvideo",
        "-pix_fmt", "yuv420p",
        "-video_size", f"{width}x{height}",
        "-framerate", str(fps),
        "-i", "pipe:0",
        "-c:v", "h264_nvenc",
        "-preset", "p1",        # fastest preset
        "-tune", "ull",         # ultra-low-latency
        "-b:v", bitrate,
        "-maxrate", bitrate,
        "-bufsize", str(int(bitrate.replace("k","")) * 2) + "k",
        "-g", str(fps * 2),
        "-flvflags", "no_duration_filesize",
        "-f", "flv",
        output_url
    ]
    return subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)


def warmup_writer(writer, width, height, num_frames=3):
    """Send black frames (YUV420P) to initialize NVENC encoder before real data."""
    yuv_size = width * height * 3 // 2
    black = bytes(yuv_size)
    for _ in range(num_frames):
        writer.stdin.write(black)
    writer.stdin.flush()


def unsharp_mask(tensor, sigma=1.0, strength=0.5):
    """Apply unsharp mask on GPU: sharp = img + strength*(img - blur(img)).
    tensor shape: (3, H, W) float32 [0,1]."""
    # Build Gaussian kernel
    ksize = int(sigma * 6) | 1  # ensure odd
    x = torch.arange(ksize, device=tensor.device, dtype=torch.float32) - ksize // 2
    kernel_1d = torch.exp(-0.5 * (x / sigma) ** 2)
    kernel_1d = kernel_1d / kernel_1d.sum()
    kernel_2d = kernel_1d[:, None] * kernel_1d[None, :]
    kernel_2d = kernel_2d.expand(3, 1, -1, -1)  # (3, 1, k, k) for depthwise conv
    pad = ksize // 2
    img = tensor.unsqueeze(0)  # (1, 3, H, W)
    blurred = F.conv2d(img, kernel_2d, padding=pad, groups=3)
    sharp = img + strength * (img - blurred)
    return sharp.squeeze(0).clamp(0, 1)


def rgb_to_yuv420p(rgb_tensor, target_h=None, target_w=None, sharpen_strength=0.0):
    """Convert (3, H, W) float32 [0,1] GPU tensor to YUV420P bytes.
    Optionally downscales to target size on GPU before conversion."""
    if target_h and target_w and (target_h != rgb_tensor.shape[1] or target_w != rgb_tensor.shape[2]):
        # Downscale on GPU using bicubic interpolation (preserves sharpness)
        rgb_tensor = F.interpolate(
            rgb_tensor.unsqueeze(0), size=(target_h, target_w),
            mode='bicubic', align_corners=False
        ).squeeze(0).clamp(0, 1)

    # Apply unsharp mask for visible sharpening
    if sharpen_strength > 0:
        rgb_tensor = unsharp_mask(rgb_tensor, sigma=1.0, strength=sharpen_strength)

    r, g, b = rgb_tensor[0], rgb_tensor[1], rgb_tensor[2]

    # Y plane (full resolution)
    y = (65.481 * r + 128.553 * g + 24.966 * b + 16.0).clamp(0, 255).byte()

    # U/V at half resolution (4:2:0 chroma subsampling)
    r2, g2, b2 = r[::2, ::2], g[::2, ::2], b[::2, ::2]
    u = (-37.797 * r2 - 74.203 * g2 + 112.0 * b2 + 128.0).clamp(0, 255).byte()
    v = (112.0 * r2 - 93.786 * g2 - 18.214 * b2 + 128.0).clamp(0, 255).byte()

    # Single GPU→CPU transfer
    yuv = torch.cat([y.flatten(), u.flatten(), v.flatten()])
    return yuv.cpu().numpy().tobytes()


def probe_stream(input_url):
    """Get width, height, fps from input stream."""
    cmd = [
        "ffprobe", "-v", "quiet",
        "-select_streams", "v:0",
        "-show_entries", "stream=width,height,r_frame_rate",
        "-of", "csv=p=0",
        input_url
    ]
    for attempt in range(30):
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            if result.returncode == 0 and result.stdout.strip():
                parts = result.stdout.strip().split(",")
                w, h = int(parts[0]), int(parts[1])
                fps_parts = parts[2].split("/")
                fps = int(fps_parts[0]) / int(fps_parts[1]) if len(fps_parts) == 2 else float(fps_parts[0])
                return w, h, fps
        except Exception:
            pass
        print(f"[upscaler] Waiting for input stream... (attempt {attempt+1}/30)")
        time.sleep(2)
    raise RuntimeError(f"Could not probe stream: {input_url}")


def main():
    parser = argparse.ArgumentParser(description="AI Video Upscaler")
    parser.add_argument("--input", required=True, help="Input RTMP URL")
    parser.add_argument("--output", required=True, help="Output RTMP URL")
    parser.add_argument("--scale", type=int, default=2, choices=[2, 3, 4],
                        help="Upscale factor (default: 2)")
    parser.add_argument("--bitrate", default="12000k",
                        help="Output bitrate (default: 12000k)")
    parser.add_argument("--quality", default="high",
                        choices=["low", "medium", "high"],
                        help="Maxine quality level (default: high)")
    parser.add_argument("--target-fps", type=int, default=20,
                        help="Target output FPS (default: 20, limited by GPU)")
    parser.add_argument("--sharpen", action="store_true",
                        help="Output at input resolution (super-sample for sharpening)")
    parser.add_argument("--sharpen-strength", type=float, default=0.7,
                        help="Unsharp mask strength (0=off, 0.5=subtle, 1.0=strong, default: 0.7)")
    args = parser.parse_args()

    # Map quality
    quality_map = {
        "low": VideoSuperRes.QualityLevel.LOW,
        "medium": VideoSuperRes.QualityLevel.MEDIUM,
        "high": VideoSuperRes.QualityLevel.HIGH,
    }

    target_fps = args.target_fps

    print(f"[upscaler] Probing input: {args.input}")
    in_w, in_h, fps = probe_stream(args.input)
    sr_w, sr_h = in_w * args.scale, in_h * args.scale  # internal upscale resolution
    # Output at input res (sharpen mode) or upscaled res
    if args.sharpen:
        out_w, out_h = in_w, in_h
    else:
        out_w, out_h = sr_w, sr_h
    frame_size = in_w * in_h * 3  # RGB24

    mode_str = "sharpen (super-sample)" if args.sharpen else f"{args.scale}x upscale"
    print(f"[upscaler] Input:  {in_w}x{in_h} @ {fps:.1f}fps")
    print(f"[upscaler] Output: {out_w}x{out_h} @ {target_fps}fps ({args.bitrate})")
    print(f"[upscaler] Mode:   {mode_str}, internal {sr_w}x{sr_h}, quality={args.quality}, usm={args.sharpen_strength}")
    print(f"[upscaler] GPU:    {torch.cuda.get_device_name(0)}")

    # Init Maxine Super Resolution
    sr = VideoSuperRes(quality=quality_map[args.quality], device=0)
    sr.output_width = sr_w
    sr.output_height = sr_h
    sr.load()
    print("[upscaler] Maxine VideoSuperRes loaded")

    # Start FFmpeg writer first and warm up NVENC (takes ~4s to init)
    writer = create_ffmpeg_writer(args.output, out_w, out_h, target_fps,
                                  args.bitrate)
    print("[upscaler] Warming up NVENC encoder...")
    warmup_writer(writer, out_w, out_h, num_frames=5)
    time.sleep(1)  # let NVENC initialize
    print("[upscaler] NVENC ready")

    # Start FFmpeg reader throttled to target FPS
    reader = create_ffmpeg_reader(args.input, in_w, in_h, target_fps)
    print(f"[upscaler] FFmpeg pipelines started (reader @ {target_fps}fps)")

    frame_count = 0
    start_time = time.time()
    fps_report_interval = 50
    t_read_total = 0
    t_upload_total = 0
    t_infer_total = 0
    t_download_total = 0
    t_write_total = 0

    try:
        while not shutdown:
            # Read one frame
            t0 = time.time()
            raw = reader.stdout.read(frame_size)
            t1 = time.time()
            if len(raw) < frame_size:
                print("[upscaler] Input stream ended or error, reconnecting...")
                reader.kill()
                time.sleep(2)
                reader = create_ffmpeg_reader(args.input, in_w, in_h, target_fps)
                continue

            # Convert to torch tensor: (H, W, 3) uint8 → (3, H, W) float32 [0,1]
            frame_np = np.frombuffer(raw, dtype=np.uint8).reshape(in_h, in_w, 3).copy()
            frame_tensor = torch.from_numpy(frame_np).cuda().permute(2, 0, 1).contiguous().float() / 255.0
            t2 = time.time()

            # AI upscale
            result = sr.run(frame_tensor)
            upscaled = torch.from_dlpack(result.image)  # (3, sr_h, sr_w) float32
            t3 = time.time()

            # Convert to YUV420P on GPU (with optional downscale for sharpen mode)
            sharpen_str = args.sharpen_strength if args.sharpen else 0.0
            out_bytes = rgb_to_yuv420p(upscaled, target_h=out_h, target_w=out_w,
                                       sharpen_strength=sharpen_str)
            t4 = time.time()

            # Start writer after first frame is processed (so RTMP doesn't timeout)
            # Write to output
            writer.stdin.write(out_bytes)
            t5 = time.time()

            t_read_total += t1 - t0
            t_upload_total += t2 - t1
            t_infer_total += t3 - t2
            t_download_total += t4 - t3
            t_write_total += t5 - t4

            frame_count += 1
            if frame_count % fps_report_interval == 0:
                elapsed = time.time() - start_time
                actual_fps = frame_count / elapsed
                print(f"[upscaler] {frame_count} frames, {actual_fps:.1f} fps "
                      f"| read={t_read_total/frame_count*1000:.0f}ms "
                      f"upload={t_upload_total/frame_count*1000:.0f}ms "
                      f"infer={t_infer_total/frame_count*1000:.0f}ms "
                      f"download={t_download_total/frame_count*1000:.0f}ms "
                      f"write={t_write_total/frame_count*1000:.0f}ms")

    except BrokenPipeError:
        print("[upscaler] Output pipe broken")
        # Get FFmpeg writer stderr
        try:
            _, stderr = writer.communicate(timeout=3)
            if stderr:
                print(f"[upscaler] FFmpeg writer error: {stderr.decode()[:500]}")
        except Exception:
            pass
    except Exception as e:
        print(f"[upscaler] Error: {e}")
    finally:
        print("[upscaler] Cleaning up...")
        sr.close()
        reader.kill()
        try:
            writer.stdin.close()
        except Exception:
            pass
        writer.kill()
        elapsed = time.time() - start_time
        if frame_count > 0:
            print(f"[upscaler] Processed {frame_count} frames in {elapsed:.1f}s "
                  f"({frame_count/elapsed:.1f} fps avg)")


if __name__ == "__main__":
    main()
