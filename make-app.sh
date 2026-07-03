#!/bin/bash
set -euo pipefail

APP="AutoRaise.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"

# 1) Build the engine CLI binary (existing Makefile target -> ./AutoRaise).
make AutoRaise

# 2) Build the launcher executable (SwiftPM, release).
swift build -c release
LAUNCHER_BIN="$(swift build -c release --show-bin-path)/AutoRaiseLauncher"

# 3) Assemble the bundle.
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
cp "$LAUNCHER_BIN" "$MACOS/AutoRaise"
cp ./AutoRaise     "$MACOS/AutoRaiseEngine"
cp Launcher/Info.plist "$CONTENTS/Info.plist"
[ -f AutoRaise.icns ] && cp AutoRaise.icns "$RES/AutoRaise.icns" || true

# 4) Code sign. Prefer a stable self-signed identity (so the Accessibility grant
#    persists across rebuilds); otherwise fall back to ad-hoc.
IDENTITY="AutoRaise Self-Signed"
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    SIGN="$IDENTITY"
else
    echo "warning: '$IDENTITY' not found; using ad-hoc signing (Accessibility grant resets each rebuild)"
    SIGN="-"
fi
codesign --force --sign "$SIGN" "$MACOS/AutoRaiseEngine"
codesign --force --sign "$SIGN" "$APP"

echo "Built $APP (signed with: $SIGN)"
