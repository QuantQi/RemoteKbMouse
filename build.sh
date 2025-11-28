#!/bin/bash
set -e

cd "$(dirname "$0")"

# Try to find a valid signing identity, fall back to ad-hoc signing
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development" | head -1 | sed 's/.*"\(.*\)".*/\1/' || echo "")

if [ -z "$IDENTITY" ]; then
    echo "No Apple Development certificate found, using ad-hoc signing..."
    SIGN_ARGS="-"
else
    echo "Using identity: $IDENTITY"
    SIGN_ARGS="$IDENTITY"
fi

echo ""
echo "Building..."
swift build -c release

echo "Signing Client..."
codesign --force --sign "$SIGN_ARGS" --entitlements Client.entitlements .build/release/Client

echo "Signing Host..."
codesign --force --sign "$SIGN_ARGS" --entitlements Host.entitlements .build/release/Host

echo ""
echo "Done! Binaries are in .build/release/"
echo "  - Client"
echo "  - Host"
echo ""
echo "IMPORTANT: Add both apps to Accessibility in System Settings!"
