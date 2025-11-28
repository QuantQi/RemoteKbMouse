#!/bin/bash
set -e

cd "$(dirname "$0")"

IDENTITY="Apple Development: soubhiks@hotmail.com (X58CWNH2T5)"

echo "Building..."
swift build -c release

echo "Signing Client..."
codesign --force --sign "$IDENTITY" --entitlements Client.entitlements --options runtime .build/release/Client

echo "Signing Host..."
codesign --force --sign "$IDENTITY" --entitlements Host.entitlements --options runtime .build/release/Host

echo ""
echo "Done! Binaries are in .build/release/"
echo "  - Client"
echo "  - Host"
