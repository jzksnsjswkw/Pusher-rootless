#!/bin/bash
# Build and install.
#
# `internal-stage` + `before-package` + `internal-package` keeps the Swift module
# cache — the top-level `all` target wipes it, which is what made every build take
# five minutes. `stage` would pull in `all`, so it must not be used, and
# `before-package` is what creates `.theos/_/DEBIAN`; skipping it fails at dm.pl.
# Both must run every time: `internal-package` consumes the staging directory.
#
# `Resources/` is copied into the bundle by `shared-instance-bundle-all`, which
# hangs off `all` — so the incremental path never refreshes it. When a resource
# changed, the whole thing has to go through `make package`.
#
# A scheme change also forces the full path. `.theos/_` is not emptied between
# builds, so switching from rootless to roothide left the previous scheme's arm64
# bundle in place and the device refused to load it ("incompatible architecture,
# have arm64, need arm64e"). The stamp file records which scheme staged last.
set -euo pipefail
cd "$(dirname "$0")/.."

SCHEME=roothide
DEVICE=root@192.168.0.219

DEB=$(ls -t packages/*_iphoneos-arm64e.deb 2>/dev/null | head -1)
NEEDS_STAGE=0
if [ -z "$DEB" ]; then
    NEEDS_STAGE=1
else
    # Compare against the package itself: anything newer than the deb has not
    # been shipped yet. A missing `.theos/obj` is normal after `make clean`.
    # Everything that goes into the package without being compiled: the two
    # resource trees, every service plist, and the control file itself. A plist
    # edit that skipped the full stage would ship the previous build's bundle.
    SCHEME_STAMP=.theos/.staged-scheme
    if [ -f "$SCHEME_STAMP" ] && [ "$(cat "$SCHEME_STAMP")" != "$SCHEME" ]; then
        NEEDS_STAGE=1
    fi

    # The stamp records which scheme last *ran* here, and it is written by this
    # script — so a build started by hand for the other scheme leaves it saying
    # roothide while `.theos/_` holds arm64. That is how an arm64 Preferences
    # bundle reached a roothide device and the page refused to load. The staged
    # file's own architecture is the fact; the stamp is only a hint.
    for staged in .theos/_/Library/PreferenceBundles/Pusher.bundle/Pusher \
                   .theos/_/Library/MobileSubstrate/DynamicLibraries/Pusher.dylib; do
        [ -f "$staged" ] || continue
        want=arm64e
        [ "$SCHEME" = "rootless" ] && want=arm64
        if ! lipo -info "$staged" 2>/dev/null | grep -qw "$want"; then
            echo "→ staged $(basename "$staged") is not $want"
            NEEDS_STAGE=1
        fi
    done

NEWER=$(find Sources -type f \( -name '*.plist' -o -path '*/Resources/*' \) \
                 -newer "$DEB" 2>/dev/null | head -1)
    [ -z "$NEWER" ] && NEWER=$(find control Makefile -newer "$DEB" -type f 2>/dev/null | head -1)
    [ -n "$NEWER" ] && NEEDS_STAGE=1
fi

# The build's exit status is the only thing that says whether a deploy is safe, so
# make is run on its own and its status read directly. Piping it into grep would
# lose that: `grep` exits 1 when it matches nothing, and with `pipefail` that is
# indistinguishable from a failed compile.
LOG=$(mktemp)
STAMP=$(mktemp)
trap 'rm -f "$LOG" "$STAMP"' EXIT

if [ "$NEEDS_STAGE" = "1" ]; then
    echo "→ resources changed: full stage"
    THEOS_PACKAGE_SCHEME=$SCHEME make clean >/dev/null 2>&1 || true
    # `clean` removes `.theos`, including the build-session file the Swift
    # compiler is told to read. Its rule creates the file, but under `-j` the
    # directory and the file are two recipe lines that can run out of order, and
    # the compile then fails with "no such file or directory: build_session".
    mkdir -p .theos && touch .theos/build_session
    BUILD_ARGS=(package)
else
    echo "→ code only: incremental"
    # `internal-all` is what compiles. It sounds like a leftover, but skipping it
    # is how a `.swift` edit gets silently ignored: `internal-stage` only copies
    # the bundle that is already on disk. It is safe to call directly — the
    # Swift-cache wipe lives in `before-all`, which this does not pull in.
    #
    # `before-stage` is what empties `.theos/_`; without it a leftover
    # DEBIAN/control ships the previous description, and a leftover from the
    # other scheme ships files at the wrong install prefix.
    BUILD_ARGS=(internal-all before-stage internal-stage before-package internal-package)
fi

# A marker with the build's start time: the deb that comes out of it must be
# newer than this, which is what proves the packaging step actually ran instead of
# silently reusing the previous output.
touch "$STAMP"

# Parallel make, on the core count. Swift is compiled whole-module — one `swiftc`
# for the module — so `-j` mostly helps the ObjC files, the bundles and the packing
# steps that surround it. The inside of that one invocation is parallelised by
# `-num-threads`, which the Makefiles set.
JOBS=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
if ! THEOS_PACKAGE_SCHEME=$SCHEME make -j"$JOBS" "${BUILD_ARGS[@]}" >"$LOG" 2>&1; then
    echo "build failed:" >&2
    grep -E "error:|Error " "$LOG" | tail -20 >&2 || tail -20 "$LOG" >&2
    exit 1
fi
mkdir -p .theos && printf '%s' "$SCHEME" > "$SCHEME_STAMP"
grep -E "building package" "$LOG" | tail -1

# `ls … | head` under `pipefail` fails when `ls` takes SIGPIPE closing the pipe, and
# with no deb at all it fails for a second reason — both used to look like a build
# problem on the very first deploy. `find -newer` also guarantees the file came out
# of *this* build rather than a previous one.
DEB=$(find packages -maxdepth 1 -name '*_iphoneos-arm64e.deb' -newer "$STAMP" -print 2>/dev/null \
      | sort | tail -1)
if [ -z "$DEB" ]; then
    echo "no roothide deb was produced by this build" >&2
    exit 1
fi

scp -q -o BatchMode=yes "$DEB" $DEVICE:/tmp/pusher.deb

# `dpkg -i` exits 0 for a package that unpacks but fails to configure, so the
# install log is checked for the line that says it was configured.
if ! ssh -o BatchMode=yes $DEVICE \
    'dpkg -i /tmp/pusher.deb > /tmp/pusher-install.log 2>&1; grep -E "Setting up|error" /tmp/pusher-install.log; grep -q "^Setting up" /tmp/pusher-install.log'; then
    echo "installation failed on the device — see /tmp/pusher-install.log" >&2
    exit 1
fi

# Replacing a dylib does not replace what a running process has loaded, so every
# process this tweak injects into has to restart. `internal-package` is the
# incremental path and does not run the `after-install` hook, which is why this is
# here rather than only in the Makefile.
#
# SpringBoard is killed last: it is the one that comes back with the UI, and
# killing it first would leave the other kills racing a respring.
ssh -o BatchMode=yes $DEVICE 'killall -9 imagent 2>/dev/null || true'
ssh -o BatchMode=yes $DEVICE 'killall -9 SpringBoard 2>/dev/null || true' 
