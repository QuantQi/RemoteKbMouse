#!/bin/bash
set -e

cd "$(dirname "$0")"

IDENTITY="Apple Development: soubhiks@hotmail.com (X58CWNH2T5)"

echo "Building..."
swift build -c release

echo "Signing Client..."
# Note: No --options runtime for Client, as CGEvent posting doesn't work with hardened runtime
codesign --force --sign "$IDENTITY" .build/release/Client

echo "Signing Host..."
# Note: No --options runtime for Host, as CGEvent tapping doesn't work with hardened runtime
codesign --force --sign "$IDENTITY" .build/release/Host

echo ""
echo "Done! Binaries are in .build/release/"
echo "  - Client"
echo "  - Host"
echo ""
echo "IMPORTANT: Add both apps to Accessibility in System Settings!"
