#!/bin/bash
# Signs Sparkle's nested helpers with the release identity, innermost first, then reseals the app.
# Xcode's "Code Sign on Copy" signs only the framework itself and leaves its helpers ad-hoc signed.
# Order and flags from Sparkle's documentation (Sandboxing and Code Signing: signing without archive export).
# Usage: resign-sparkle.sh Workdeck.app "Apple Development" [keychain]
set -euo pipefail
APP="$1"
IDENTITY="$2"
KEYCHAIN_ARGS=()
if [ -n "${3:-}" ]; then KEYCHAIN_ARGS=(--keychain "$3"); fi
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
sign() { codesign -f -s "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} -o runtime "$@"; }
sign "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
sign "$SPARKLE/Versions/B/Autoupdate"
sign "$SPARKLE/Versions/B/Updater.app"
sign "$SPARKLE"
# Reseal the app over the new nested signatures, keeping its own entitlements and flags.
codesign -f -s "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --preserve-metadata=entitlements,requirements,flags,runtime "$APP"
