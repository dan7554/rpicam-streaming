#!/bin/bash
# Install local CA certificate in macOS Keychain Access

CA_CERT="/Users/dchristiani/code/media-mtx/broadcast-system/certs/ca/ca.crt"

if [ ! -f "$CA_CERT" ]; then
  echo "❌ CA certificate not found at $CA_CERT"
  exit 1
fi

echo "🔐 Installing Local CA Certificate in Keychain Access..."
echo ""
echo "Follow these steps:"
echo ""
echo "1. Open Keychain Access (this will open automatically):"
open /Applications/Utilities/Keychain\ Access.app

sleep 2

echo ""
echo "2. In Keychain Access, go to: File → Import Items..."
echo "3. Navigate to: $CA_CERT"
echo "4. Click 'Open'"
echo ""
echo "5. When prompted, select 'System' keychain and click 'Add'"
echo ""
echo "6. In the main keychain window, find 'Local CA' certificate"
echo ""
echo "7. Double-click on 'Local CA' certificate"
echo ""
echo "8. Expand the 'Trust' section"
echo ""
echo "9. Change 'When using this certificate:' to 'Always Trust'"
echo ""
echo "10. Close the window (you'll be prompted to save - click 'Update')"
echo ""
echo "11. Restart Chrome/Safari"
echo ""
echo "✅ Done! local.broadcast.com should now show as secure in your browser"
echo ""
