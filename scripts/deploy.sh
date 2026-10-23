#!/bin/bash
# Build and install.
#
# `make internal-package` keeps the Swift module cache — the top-level `all` target
# wipes it, which is what made every build take five minutes. But `internal-stage`
# does not rebuild the Preferences bundle from `Resources/`, so a plist or icon
# change has to go through the full stage. So: the incremental path for code, and
# the full path when anything under Resources/ is newer than the last package.
set -e
cd "$(dirname "$0")/.."

SCHEME=roothide
DEVICE=root@192.168.0.219

# Anything under Resources/ newer than the package means the bundle must be rebuilt.
DEB=$(ls -t packages/*arm64e.deb 2>/dev/null | head -1)
NEEDS_STAGE=0
if [ -z "$DEB" ]; then
    NEEDS_STAGE=1
else
    NEWER=$(find Sources/Preferences/Resources Sources/Flipswitch -newer "$DEB" -type f 2>/dev/null | head -1)
    [ -n "$NEWER" ] && NEEDS_STAGE=1
fi

if [ "$NEEDS_STAGE" = "1" ]; then
    echo "→ resources changed: full stage"
    THEOS_PACKAGE_SCHEME=$SCHEME make package 2>&1 | grep -E "error:|building package" | tail -3
else
    echo "→ code only: incremental"
    THEOS_PACKAGE_SCHEME=$SCHEME make internal-package 2>&1 | grep -E "error:|building package" | tail -3
fi

DEB=$(ls -t packages/*arm64e.deb | head -1)
scp -q -o BatchMode=yes "$DEB" $DEVICE:/tmp/pusher.deb
ssh -o BatchMode=yes $DEVICE 'dpkg -i /tmp/pusher.deb 2>&1 | grep -E "Setting up|error"'
