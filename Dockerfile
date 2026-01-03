# Use the MediaMTX image with FFmpeg support (AMD64 for AWS Fargate deployment)
# Explicitly specify linux/amd64 architecture
FROM --platform=linux/amd64 bluenviron/mediamtx:1.15.5

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

# Set environment variables for MediaMTX configuration
ENV MTX_RTSPTRANSPORTS=tcp
ENV MTX_WEBRTCADDITIONALHOSTS=localhost

# Expose the ports used by MediaMTX
EXPOSE 8554/tcp
EXPOSE 1935/tcp
EXPOSE 8888/tcp
EXPOSE 8889/tcp
EXPOSE 8890/tcp
EXPOSE 8891/udp
EXPOSE 9996/tcp
EXPOSE 9997/tcp
EXPOSE 9998/tcp
EXPOSE 9999/tcp
EXPOSE 8189/udp

# No Docker HEALTHCHECK: rely on ALB target-group for readiness

# Base image entrypoint is /mediamtx which looks for mediamtx.yml in current directory
# We're in /app and have copied mediamtx.yml there
# Do NOT override the base image entrypoint - ECS will provide the command as needed
# The base image ENTRYPOINT is /mediamtx, and ECS will pass /app/mediamtx.yml as the command argument