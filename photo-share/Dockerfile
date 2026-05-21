FROM golang:1.22-alpine AS builder
WORKDIR /build
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o photoshare .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates tzdata
RUN adduser -D -s /bin/false photoshare
WORKDIR /app
COPY --from=builder /build/photoshare .
RUN mkdir -p /app/data && chown photoshare:photoshare /app/data
USER photoshare
ENV DATA_DIR=/app/data
EXPOSE 8080
ENTRYPOINT ["./photoshare"]
