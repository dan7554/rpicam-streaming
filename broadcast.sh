#!/bin/bash
# Quick access script for the broadcast system

HOSTNAME="local.broadcast.com"
PROTOCOL="https"

case "${1:-help}" in
  web)
    echo "Opening web UI: $PROTOCOL://$HOSTNAME/"
    open "$PROTOCOL://$HOSTNAME/" || xdg-open "$PROTOCOL://$HOSTNAME/" || echo "Please open $PROTOCOL://$HOSTNAME/ in your browser"
    ;;
  api)
    echo "API Base URL: $PROTOCOL://$HOSTNAME/api"
    echo ""
    echo "Available endpoints:"
    echo "  • /health          - System health status"
    echo "  • /cameras         - List all cameras"
    echo "  • /scenes          - List all scenes"
    echo "  • /config          - Configuration"
    echo ""
    echo "Example:"
    echo "  curl -k $PROTOCOL://$HOSTNAME/api/health | jq"
    ;;
  health)
    echo "Checking system health..."
    curl -k -s "$PROTOCOL://$HOSTNAME/api/health" | jq .
    ;;
  cameras)
    echo "Fetching cameras..."
    curl -k -s "$PROTOCOL://$HOSTNAME/api/cameras" | jq '.data[] | {id, name, status, type}'
    ;;
  logs)
    echo "Streaming broadcast-system logs (Ctrl+C to stop)..."
    docker logs -f broadcast-system
    ;;
  restart)
    echo "Restarting broadcast-system..."
    docker compose restart broadcast-system
    sleep 2
    echo "✅ Broadcast system restarted"
    ;;
  status)
    echo "🔍 Broadcast System Status"
    echo ""
    docker ps --filter name=broadcast --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
    ;;
  cert)
    echo "📜 SSL Certificate Information"
    openssl x509 -in broadcast-system/certs/server.crt -text -noout 2>/dev/null | grep -E "Subject:|Issuer:|Not Before|Not After|CN="
    ;;
  hosts)
    echo "Checking /etc/hosts entry..."
    if grep -q "$HOSTNAME" /etc/hosts; then
      echo "✅ $HOSTNAME is configured in /etc/hosts:"
      grep "$HOSTNAME" /etc/hosts
    else
      echo "❌ $HOSTNAME not found in /etc/hosts"
      echo "Add it with: echo '127.0.0.1 $HOSTNAME' | sudo tee -a /etc/hosts"
    fi
    ;;
  *)
    echo "Broadcast System CLI Tool"
    echo ""
    echo "Usage: $0 [command]"
    echo ""
    echo "Commands:"
    echo "  web              Open web UI in browser"
    echo "  api              Show API documentation"
    echo "  health           Check system health"
    echo "  cameras          List all cameras"
    echo "  logs             Stream container logs"
    echo "  restart          Restart broadcast-system container"
    echo "  status           Show container status"
    echo "  cert             Show SSL certificate info"
    echo "  hosts            Check hostname configuration"
    echo "  help             Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 web                # Open web UI"
    echo "  $0 health             # Check health"
    echo "  $0 cameras            # List cameras"
    echo ""
    ;;
esac
