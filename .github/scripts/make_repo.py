#!/usr/bin/env python3
"""Builds the APT index this source serves, from one release's debs plus the
stanzas the previous index already carried.

Why a parser rather than line editing: `Packages` is RFC822, and the fields that
matter here — `Description` above all — have continuation lines whose leading
space is significant. Anything that rewrites a stanza by matching lines
eventually strips one, and apt rejects the whole index when a description
becomes a bare line. `python-debian`'s `Deb822` parses and re-emits a stanza
without losing anything, so a package this run did not build comes back
byte-identical.

Why the carry-forward exists at all: this branch is shared. `jzksnsjswkw/repo`
serves Relocate and Pusher, and each project's workflow publishes the whole
directory. An index built from only the current release's debs silently deletes
every other project's row — which is exactly what happened to Relocate when this
script was a shell loop that knew nothing about anything it was not handed.

Usage:
    make_repo.py --tag v3.0.1 --out repo \
                 [--previous old/Packages] [--debs a.deb b.deb] \
                 [--mirrored packages/mirrored]
"""

from __future__ import annotations

import argparse
import bz2
import gzip
import hashlib
import lzma
import os
import shutil
import subprocess
import sys
from pathlib import Path

try:
    from debian.deb822 import Deb822
except ImportError:  # pragma: no cover - deployment-time dependency
    sys.exit("python-debian is required: pip install python-debian")


PAGES_URL = os.environ.get("PAGES_URL", "https://jzksnsjswkw.github.io/repo")
PUSHER_RELEASES = os.environ.get(
    "RELEASES_URL", "https://github.com/jzksnsjswkw/Pusher-rootless/releases/download"
)

# Packages this project used to publish under, or publishes under a name that a
# newer build replaced. Carrying one of these forward would list a package that
# cannot be installed beside the one that superseded it.
#
# `com.jzksnsjswkw.pusher` is the bare name every build used before the two
# schemes were merged; `-roothide` is the other half of that split.
OBSOLETE = {
    "com.jzksnsjswkw.pusher",
    "com.jzksnsjswkw.pusher-roothide",
}

DEPICTION_DIR = Path(".github/scripts/depiction")
DEPICTION_FILES = [
    "pusher.json",
    "shots/1-settings.png",
    "shots/2-add.png",
    "shots/3-instance.png",
    "shots/4-filter.png",
]
DEPICTION_JSON = f"{PAGES_URL}/depiction/pusher.json"

SCRIPT_DIR = Path(__file__).resolve().parent

RELEASE_HEADER = """Origin: jzksnsjswkw
Label: jzksnsjswkw
Suite: stable
Version: 1.0
Codename: ios
Architectures: iphoneos-arm64e iphoneos-arm64
Components: main
Description: Notification forwarding for iOS
Icon: file://CydiaIcon@2x.png"""


def control(deb: Path) -> Deb822:
    """The deb's own control stanza."""
    raw = subprocess.run(
        ["dpkg-deb", "-f", str(deb)], capture_output=True, check=True
    ).stdout
    return Deb822(raw.decode("utf-8"))


def field(stanza: Deb822, name: str, fallback: str = "") -> str:
    return stanza.get(name) or fallback


def digest(data: bytes) -> tuple[str, str, str]:
    return (
        hashlib.md5(data).hexdigest(),
        hashlib.sha1(data).hexdigest(),
        hashlib.sha256(data).hexdigest(),
    )


def served_name(deb: Path) -> str:
    """The name the file is served under.

    GitHub rewrites `~` to `.` in an uploaded asset's name — the `~` is dpkg's
    prerelease marker and survives in `Version:`, but not in a filename — so the
    URL and the local path disagree for any prerelease. The index has to carry
    the one the server actually uses.
    """
    return deb.name.replace("~", ".")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="release tag the debs belong to")
    ap.add_argument("--out", default="repo", help="directory to write the index into")
    ap.add_argument(
        "--previous",
        help="the live Packages file; its stanzas for other projects are carried",
    )
    ap.add_argument("--debs", nargs="*", default=[], help="this release's debs")
    ap.add_argument(
        "--mirrored",
        default="packages/mirrored",
        help="debs of other projects this source serves (dependencies)",
    )
    args = ap.parse_args()

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)

    mirrored_dir = Path(args.mirrored)
    mirrored = sorted(mirrored_dir.glob("*.deb")) if mirrored_dir.is_dir() else []

    # --- this release's packages -------------------------------------------

    published: list[Deb822] = []
    icons: dict[str, Path] = {}
    seen: set[tuple[str, str]] = set()

    for path in [Path(p) for p in args.debs]:
        if not path.is_file():
            continue
        src = control(path)
        name = field(src, "Package")
        version = field(src, "Version")
        arch = field(src, "Architecture")
        if not name:
            print(f"skipping {path}: no Package field", file=sys.stderr)
            continue

        key = (name, arch)
        if key in seen:
            continue
        seen.add(key)

        stanza = Deb822()
        # Straight from the deb. Nothing is invented here: the two scheme builds
        # carry the same `Package:` and differ only in `Architecture`, and a
        # client keys a package on the pair — so Sileo lists one row and an
        # upgrade crosses schemes. A suffix added on the way out would disagree
        # with what dpkg recorded as installed.
        stanza["Package"] = name
        stanza["Name"] = field(src, "Name", name)
        stanza["Version"] = version
        if field(src, "Provides"):
            stanza["Provides"] = src["Provides"]
        stanza["Architecture"] = arch
        stanza["Section"] = field(src, "Section", "Tweaks")
        stanza["Priority"] = "optional"
        stanza["Maintainer"] = field(src, "Maintainer", "jzksnsjswkw")
        stanza["Installed-Size"] = field(src, "Installed-Size", "0")
        stanza["Depends"] = field(
            src, "Depends", "firmware (>= 15.0), mobilesubstrate"
        )

        icon = field(src, "Icon")
        if icon:
            stanza["Icon"] = icon
            # The icon file has to exist in the published tree, because a client
            # fetches it before anything is installed. Read the name back out of
            # the control rather than assuming one: a shared filename lets a
            # second project's icon overwrite this one.
            if icon.startswith(PAGES_URL):
                icon_name = icon.rsplit("/", 1)[-1]
                source = SCRIPT_DIR / icon_name
                if not source.is_file():
                    sys.exit(
                        f"error: {source} is missing — {path.name} would list a "
                        f"broken icon"
                    )
                icons[icon_name] = source

        if field(src, "Depiction"):
            stanza["Depiction"] = src["Depiction"]
        if field(src, "Author"):
            stanza["Author"] = src["Author"]
        stanza["Sileodepiction"] = DEPICTION_JSON

        data = path.read_bytes()
        stanza["Filename"] = f"{PUSHER_RELEASES}/{args.tag}/{served_name(path)}"
        stanza["Size"] = str(len(data))
        md5, _, sha256 = digest(data)
        stanza["MD5sum"] = md5
        stanza["SHA256"] = sha256
        stanza["Description"] = field(
            src, "Description", "Push notifications to other devices"
        )
        published.append(stanza)

    # --- mirrored dependencies ---------------------------------------------

    for path in mirrored:
        if not path.is_file():
            continue
        src = control(path)
        name = field(src, "Package")
        arch = field(src, "Architecture")
        if not name or (name, arch) in seen:
            continue
        seen.add((name, arch))

        stanza = Deb822()
        for key in (
            "Package", "Name", "Version", "Architecture", "Maintainer", "Author",
            "Section", "Description", "Depends", "Installed-Size", "Provides",
        ):
            if field(src, key):
                stanza[key] = src[key]
        # Served from this source rather than from the upstream release: a client
        # installing the package that depends on it has added only this source,
        # and an unresolved dependency here stops the install half way.
        stanza["Filename"] = f"{PAGES_URL}/debs/{served_name(path)}"
        data = path.read_bytes()
        stanza["Size"] = str(len(data))
        md5, _, sha256 = digest(data)
        stanza["MD5sum"] = md5
        stanza["SHA256"] = sha256
        published.append(stanza)

    # --- stanzas this run did not produce ----------------------------------

    carried: list[Deb822] = []
    # A package this run published is this run's to define, completely. Carrying
    # an older stanza of the same name forward would keep an architecture this
    # release did not produce — pointing at a `Filename` whose asset may no longer
    # exist, which apt reports as a download failure rather than as a stale index.
    # Other projects' names are not in this set, so they survive.
    published_names = {stanza["Package"] for stanza in published}

    previous = Path(args.previous) if args.previous else None
    if previous and previous.is_file():
        for block in previous.read_text(encoding="utf-8").split("\n\n"):
            if not block.strip():
                continue
            stanza = Deb822(block)
            name = field(stanza, "Package")
            if not name:
                continue
            if name in OBSOLETE:
                print(f"dropped obsolete {name} from the previous index")
                continue
            if (name, field(stanza, "Architecture")) in seen:
                continue
            if name in published_names:
                print(f"dropped stale {name} {stanza.get('Architecture')} — this "
                      f"release defines the name now")
                continue
            carried.append(stanza)

    # --- write ------------------------------------------------------------

    with open(out / "Packages", "wb") as handle:
        for stanza in published + carried:
            stanza.dump(handle, encoding="utf-8")
            handle.write(b"\n")

    index = (out / "Packages").read_bytes()
    artefacts: dict[str, bytes] = {"Packages": index}
    artefacts["Packages.gz"] = gzip.compress(index, 9)
    artefacts["Packages.bz2"] = bz2.compress(index, 9)
    artefacts["Packages.xz"] = lzma.compress(index, preset=9)
    for name, data in artefacts.items():
        if name != "Packages":
            (out / name).write_bytes(data)

    # zst is what a recent apt asks for first. Written only when zstd is present,
    # and listed in `Release` only when it was: a checksum for a file that is not
    # there makes the client fail to fetch the index at all.
    if shutil.which("zstd"):
        target = out / "Packages.zst"
        result = subprocess.run(
            ["zstd", "-19", "-q", "-f", "-o", str(target)],
            input=index, capture_output=True,
        )
        if result.returncode == 0:
            artefacts["Packages.zst"] = target.read_bytes()
            target.unlink()
        else:
            print("warning: zstd failed; Packages.zst not written", file=sys.stderr)
    else:
        print("note: zstd not installed; Packages.zst not written", file=sys.stderr)

    release = [RELEASE_HEADER]
    for label, fn in (("MD5Sum", hashlib.md5), ("SHA1", hashlib.sha1),
                      ("SHA256", hashlib.sha256)):
        release.append(f"{label}:")
        for name in sorted(artefacts):
            data = artefacts[name]
            release.append(f" {fn(data).hexdigest()} {len(data)} {name}")
    (out / "Release").write_text("\n".join(release) + "\n", encoding="utf-8")

    # The source's own icon. Clients look for these exact filenames in the source
    # root — it is a filename, not a field — and pick the scale matching the
    # screen, so all three are published.
    for name in ("CydiaIcon.png", "CydiaIcon@2x.png", "CydiaIcon@3x.png"):
        source = SCRIPT_DIR / name
        if not source.is_file():
            sys.exit(f"error: {source} is missing — the source will list without "
                     f"an icon")
        shutil.copy2(source, out / name)

    for name, source in icons.items():
        shutil.copy2(source, out / name)

    # The package page. Copied in rather than linked to an outside host, for the
    # same reason the source icon is.
    for required in DEPICTION_FILES:
        if not (DEPICTION_DIR / required).is_file():
            sys.exit(f"error: {DEPICTION_DIR / required} is missing — the package "
                     f"page needs it")
    target = out / "depiction"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(
        DEPICTION_DIR, target,
        ignore=shutil.ignore_patterns("banner.png", "CydiaIcon*"),
    )

    # Mirrored debs are published here, because their `Filename` points here.
    if mirrored:
        (out / "debs").mkdir(exist_ok=True)
        for path in mirrored:
            shutil.copy2(path, out / "debs" / served_name(path))

    total = len(published) + len(carried)
    print(f"indexed {total} stanza(s) into {out}/")
    print(f"  {len(published)} from this release, {len(carried)} carried forward")
    for stanza in published:
        print(f"  + {stanza['Package']} {stanza['Version']} {stanza['Architecture']}")
    for stanza in carried:
        print(f"  · {stanza.get('Package')} {stanza.get('Version')} "
              f"{stanza.get('Architecture')} (carried)")


if __name__ == "__main__":
    main()
