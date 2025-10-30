docker run --rm -it \
-e MTX_RTSPTRANSPORTS=tcp \
-e MTX_WEBRTCADDITIONALHOSTS=localhost \
-p 8554:8554 \
-p 1935:1935 \
-p 8888:8888 \
-p 8889:8889 \
-p 9996:9996 \
-p 8890:8890/udp \
-p 8189:8189/udp \
-v ./mediamtx.yml:/mediamtx.yml \
-v ./server.crt:/server.crt \
-v ./server.key:/server.key \
bluenviron/mediamtx:1-ffmpeg-rpi