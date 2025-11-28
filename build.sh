#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building..."
swift build -c release

echo "Signing Client (ad-hoc)..."
codesign --force --sign - .build/release/Client

echo "Signing Host (ad-hoc)..."
codesign --force --sign - .build/release/Host

echo ""
echo "Done! Binaries are in .build/release/"
echo "  - Client"
echo "  - Host"
echo ""
echo "IMPORTANT: Add both apps to Accessibility in System Settings!"
