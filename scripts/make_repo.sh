#!/bin/bash
#
# Builds the APT repository index from the packages in the release.
#
# A Cydia/Sileo source is a directory with a `Packages` file in it. That file is a
# list of stanzas, one per package, carrying the fields the client shows and the
# URL it downloads from — nothing more. The whole of it is generated here so the
# index cannot drift from what was actually published.
#
# The debs themselves are not copied in: they live on the release page, and the
# `Filename` field points there. A source that carried its own copies would grow a
# git history the size of every build ever made, for files already served
# elsewhere.
set -euo pipefail

# Where the index is published, and where the debs are served from.
PAGES_URL="${PAGES_URL:-https://jzksnsjswkw.github.io/repo}"
RELEASES_URL="${RELEASES_URL:-https://github.com/jzksnsjswkw/Pusher-rootless/releases/download}"
TAG="${1:?usage: make_repo.sh <tag> [deb...]}"
shift

OUT="${OUT_DIR:-repo}"
mkdir -p "$OUT"

# The debs to index. Every release publishes two builds and both belong in the
# index; older releases stay on their own release pages and are not repeated here,
# because a client shows the newest version it finds and the rest is noise.
if [ "$#" -gt 0 ]; then
    DEBS=("$@")
else
    DEBS=(packages/*.deb)
fi

: > "$OUT/Packages"

for deb in "${DEBS[@]}"; do
    [ -f "$deb" ] || continue

    field() { dpkg-deb -f "$deb" "$1" 2>/dev/null || true; }

    name=$(field Package)
    version=$(field Version)
    arch=$(field Architecture)
    [ -n "$name" ] || continue

    # GitHub rewrites `~` to `.` in uploaded asset names, so the URL and the local
    # filename differ. The index has to carry the name the server actually uses.
    filename=$(basename "$deb" | tr '~' '.')
    size=$(stat -f%z "$deb" 2>/dev/null || stat -c%s "$deb")
    md5=$(md5 -q "$deb" 2>/dev/null || md5sum "$deb" | cut -d' ' -f1)
    sha256=$(shasum -a 256 "$deb" 2>/dev/null | cut -d' ' -f1 || sha256sum "$deb" | cut -d' ' -f1)

    # Two builds are published for every release — roothide (arm64e) and rootless
    # (arm64) — and they are the same package at the same version, differing only
    # in where they install. A client keyed on the package name alone would show
    # one entry for the two and pick whichever it saw last, so roothide's build
    # carries a suffix and a `Provides` the plain name: Sileo then lists it as its
    # own row, and anything depending on `com.noahsaso.pusher` still resolves.
    pkg_name="$name"
    provides=""
    case "$arch" in
        iphoneos-arm64e)
            pkg_name="${name}-roothide"
            provides="Provides: $name"
            ;;
        iphoneos-arm64)
            pkg_name="${name}-rootless"
            provides="Provides: $name"
            ;;
    esac

    {
        echo "Package: $pkg_name"
        echo "Version: $version"
        [ -n "$provides" ] && echo "$provides"
        echo "Architecture: $arch"
        echo "Section: $(field Section || echo Tweaks)"
        echo "Priority: optional"
        echo "Maintainer: $(field Maintainer || echo jzksnsjswkw)"
        echo "Installed-Size: $(field Installed-Size || echo 0)"
        # `firmware` is the virtual package every jailbroken device provides; the
        # constraint is what stops a client on iOS 14 from installing a build that
        # cannot run there.
        echo "Depends: $(field Depends || echo 'firmware (>= 15.0), mobilesubstrate')"
        echo "Filename: $RELEASES_URL/$TAG/$filename"
        echo "Size: $size"
        echo "MD5sum: $md5"
        echo "SHA256: $sha256"
        # The description goes on the field's own line, and any continuation lines
        # are indented by one space. A description printed as a bare line — which
        # is what a missing field name produces — makes APT reject the whole index.
        description=$(field Description)
        if [ -n "$description" ]; then
            printf '%s\n' "$description" | awk 'NR==1 { print "Description: " $0 } NR>1 { print " " $0 }'
        else
            echo "Description: Push notifications to other devices"
        fi
        echo ""
    } >> "$OUT/Packages"
done

gzip -9 -k -f "$OUT/Packages"
if command -v bzip2 >/dev/null; then
    bzip2 -9 -k -f "$OUT/Packages"
fi

# The source's own metadata: what Sileo lists it as.
cat > "$OUT/Release" <<RELEASE
Origin: Pusher
Label: Pusher
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm64e iphoneos-arm64
Components: main
Description: Notification forwarding for iOS
RELEASE

echo "Indexed $(grep -c '^Package: ' "$OUT/Packages") package(s) into $OUT/"
ls -la "$OUT"
