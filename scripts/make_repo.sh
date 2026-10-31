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

# The package page the client renders. Kept beside the index so the whole source
# is one branch, and referenced absolutely because a client fetches it directly.
DEPICTION_JSON="${DEPICTION_JSON:-$PAGES_URL/depiction/pusher.json}"

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

    # `dpkg-deb -f` exits 0 with empty output for a field that is not there, so
    # `field X || fallback` never falls back. Callers must test the value.
    field() { dpkg-deb -f "$deb" "$1" 2>/dev/null || true; }
    field_or() { local v; v=$(field "$1"); echo "${v:-$2}"; }

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
    # own row, and anything depending on `com.jzksnsjswkw.pusher` still resolves.
    # The deb already carries the scheme suffix in its `Package:` field (the
    # Makefile adds it), so the index uses the name as-is. Appending a second
    # suffix here produced `com.jzksnsjswkw.pusher-roothide-roothide`, which apt
    # would treat as yet another package.
    pkg_name="$name"
    display_name=""
    provides=""
    case "$arch" in
        iphoneos-arm64e)
            display_name="Pusher-roothide"
            ;;
        iphoneos-arm64)
            display_name="Pusher-rootless"
            ;;
    esac
    case "$name" in
        *-roothide|*-rootless) provides="Provides: ${name%-*}" ;;
    esac

    {
        echo "Package: $pkg_name"
        # The name Sileo lists. Without it the row shows the package identifier,
        # which is an implementation detail the reader has no use for.
        [ -n "$display_name" ] && echo "Name: $display_name"
        echo "Version: $version"
        [ -n "$provides" ] && echo "$provides"
        echo "Architecture: $arch"
        echo "Section: $(field_or Section Tweaks)"
        echo "Priority: optional"
        echo "Maintainer: $(field_or Maintainer jzksnsjswkw)"
        echo "Installed-Size: $(field_or Installed-Size 0)"
        # `firmware` is the virtual package every jailbroken device provides; the
        # constraint is what stops a client on iOS 14 from installing a build that
        # cannot run there.
        # The firmware floor belongs in the package's own control, where apt reads
        # it before downloading; this fallback is only for a control that forgot.
        echo "Depends: $(field_or Depends 'firmware (>= 15.0), mobilesubstrate')"
        # The icon and depiction are optional fields carried straight through from
        # the package's own control. They are what the client shows on the package
        # page, and a stanza that omits them gets a grey placeholder.
        icon=$(field Icon)
        [ -n "$icon" ] && echo "Icon: $icon"
        depiction=$(field Depiction)
        [ -n "$depiction" ] && echo "Depiction: $depiction"
        author=$(field Author)
        [ -n "$author" ] && echo "Author: $author"
        # A rich package page — the description tabs, screenshots and the version
        # list — is a JSON document the client fetches and renders; the `Description`
        # field below is only the one-line summary some clients still show. The
        # path is absolute because the client resolves it against nothing.
        [ -n "$DEPICTION_JSON" ] && echo "Sileodepiction: $DEPICTION_JSON"
        echo "Filename: $RELEASES_URL/$TAG/$filename"
        echo "Size: $size"
        echo "MD5sum: $md5"
        echo "SHA256: $sha256"
        # The description goes on the field's own line, and any continuation lines
        # are indented by one space. A description printed as a bare line — which
        # is what a missing field name produces — makes APT reject the whole index.
        description=$(field Description)
        if [ -n "$description" ]; then
            # `dpkg-deb -f` keeps the control file's continuation prefix, so the
            # lines already start with one space. Re-adding a space unconditionally
            # would leave two, and a client strips only one — the paragraph marker
            # ` .` would then render as the literal text " .".
            printf '%s\n' "$description" \
                | awk 'NR==1 { print "Description: " $0 } NR>1 { sub(/^ /, ""); print " " $0 }'
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

# The source's own metadata: what Sileo lists it as, and the picture beside it.
# `Label` is the name shown; without it the client falls back to the hostname.
# `Icon` is fetched from the source URL, so the avatar is committed to the branch
# rather than linked to GitHub's CDN — a source that depends on another host for
# its own icon disappears when that host moves.
cat > "$OUT/Release" <<RELEASE
Origin: jzksnsjswkw
Label: jzksnsjswkw
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm64e iphoneos-arm64
Components: main
Description: Notification forwarding for iOS
Icon: file://CydiaIcon@2x.png
RELEASE

# The source's icon. The clients look for a file named `CydiaIcon.png` in the
# source root — a name, not a field: there is no `Icon:` key in the Release format,
# and a file called anything else is never fetched.
# Clients pick the scale that matches the screen, so all three are published.
for name in CydiaIcon CydiaIcon@2x CydiaIcon@3x; do
    src="scripts/$name.png"
    if [ ! -f "$src" ]; then
        echo "error: $src is missing — the source will list without an icon" >&2
        exit 1
    fi
    cp "$src" "$OUT/$name.png"
done

# The package page's images. The JSON points at this source, so they are copied in
# rather than linked to an outside host, for the same reason the source icon is.
DEPICTION_DIR="${DEPICTION_DIR:-scripts/depiction}"
# Required, not optional: without the document the package page is a blank tab in
# every client, and without the screenshots it is a page with empty frames. A
# missing file used to be skipped silently, which is how a broken source shipped
# looking fine.
for required in pusher.json shots/1-settings.png shots/2-add.png \
                shots/3-instance.png shots/4-filter.png; do
    if [ ! -f "$DEPICTION_DIR/$required" ]; then
        echo "error: $DEPICTION_DIR/$required is missing — the package page needs it" >&2
        exit 1
    fi
done
if [ -d "$DEPICTION_DIR" ]; then
    mkdir -p "$OUT/depiction"
    rsync -a --exclude banner.png "$DEPICTION_DIR/" "$OUT/depiction/"
fi

# The package's own icon, referenced by the `Icon:` field in each control file.
# Served from here rather than from inside the deb because Sileo shows the icon
# before anything is installed — a `file://` path only resolves afterwards, and to
# a path that differs by packaging scheme.
PACKAGE_ICON="${PACKAGE_ICON:-scripts/icon.png}"
if [ ! -f "$PACKAGE_ICON" ]; then
    echo "error: $PACKAGE_ICON is missing — every package row will show a placeholder" >&2
    exit 1
fi
cp "$PACKAGE_ICON" "$OUT/icon.png"

echo "Indexed $(grep -c '^Package: ' "$OUT/Packages") package(s) into $OUT/"
ls -la "$OUT"
