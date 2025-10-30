# Use the MediaMTX image with FFmpeg support (AMD64 compatible for cloud deployment)
FROM bluenviron/mediamtx:1-ffmpeg

# Set working directory
WORKDIR /app

# Copy configuration files to the working directory
COPY mediamtx-container.yml /app/mediamtx.yml
COPY server.crt /app/server.crt
COPY server.key /app/server.key

# Also copy to root for compatibility (some configs expect them there)
COPY mediamtx-container.yml /mediamtx.yml
COPY server.crt /server.crt
COPY server.key /server.key

# Create recordings directory
RUN mkdir -p /app/recordings

# Set environment variables for MediaMTX configuration
ENV MTX_RTSPTRANSPORTS=tcp
ENV MTX_WEBRTCADDITIONALHOSTS=localhost

# Expose the ports used by MediaMTX
EXPOSE 8554/tcp
EXPOSE 1935/tcp
EXPOSE 8888/tcp
EXPOSE 8889/tcp
EXPOSE 9996/tcp
EXPOSE 8890/udp
EXPOSE 8189/udp

# Add health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8888/ || exit 1

# MediaMTX looks for mediamtx.yml in the working directory by default
# No need to specify the config file explicitly