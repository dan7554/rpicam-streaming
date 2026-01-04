#!/bin/bash
# Quick start guide for DNS setup with Cloudflare credentials

echo "�� DNS Setup Quick Start"
echo "========================"
echo ""

# Check if we're in the right directory
if [ ! -f "Makefile" ]; then
    echo "❌ Error: Makefile not found. Run from project root:"
    echo "   cd /Users/dchristiani/code/media-mtx"
    exit 1
fi

# Check current status
echo "📊 Current Configuration:"
echo ""
make dns-info
echo ""

# Prompt for credentials
read -p "Do you have Cloudflare API credentials? (y/n) " -n 1 -r
echo ""

if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo ""
    echo "📝 Enter your Cloudflare credentials:"
    echo ""
    read -p "   API Token: " CLOUDFLARE_API_TOKEN
    read -p "   Zone ID:   " CLOUDFLARE_ZONE_ID
    
    if [ -z "$CLOUDFLARE_API_TOKEN" ] || [ -z "$CLOUDFLARE_ZONE_ID" ]; then
        echo ""
        echo "❌ Both credentials are required."
        exit 1
    fi
    
    echo ""
    echo "🔧 Setting up DNS..."
    export CLOUDFLARE_API_TOKEN
    export CLOUDFLARE_ZONE_ID
    
    make dns-setup
    
    echo ""
    echo "✅ DNS setup complete!"
    echo ""
    read -p "Continue with full deployment? (make deploy-fargate) (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🚀 Starting full deployment..."
        make deploy-fargate
    fi
else
    echo ""
    echo "ℹ️  DNS setup skipped."
    echo ""
    echo "To get credentials:"
    echo "  1. Log in to: https://dash.cloudflare.com"
    echo "  2. Go to: My Profile → API Tokens"
    echo "  3. Create token with Zone.DNS:Edit permission"
    echo "  4. Also get Zone ID from Overview page"
    echo ""
    echo "Then run: $0"
    echo ""
    read -p "Continue with deployment anyway? (y/n) " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "🚀 Starting deployment (without DNS setup)..."
        make deploy-fargate
    fi
fi
