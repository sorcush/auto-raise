#!/bin/bash
set -euo pipefail

APP="AutoRaise.app"

# 1) Build the single merged menu-bar app (engine + UI in one binary).
#    `make` compiles AutoRaise.mm and assembles AutoRaise.app via create-app-bundle.sh.
make clean
make

# 2) Code sign. Prefer a stable self-signed identity (so the Accessibility grant
#    persists across rebuilds); otherwise fall back to ad-hoc.
#    No -v (valid-only) filter — a self-signed cert is "not trusted" for
#    distribution but signs fine and gives a stable identity for TCC persistence.
IDENTITY="AutoRaise Self-Signed"
if security find-identity -p codesigning | grep -q "$IDENTITY"; then
    SIGN="$IDENTITY"
else
    echo "warning: '$IDENTITY' not found; using ad-hoc signing (Accessibility grant resets each rebuild)"
    SIGN="-"
fi
codesign --force --deep --sign "$SIGN" "$APP"

echo "Built $APP (signed with: $SIGN)"
