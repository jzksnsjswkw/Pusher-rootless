#!/usr/bin/env python3
"""Reports service parameter names that collide with framework keys.

A service reads its settings out of the same instance object the framework keeps
its filters in. Two rules keep them apart — custom services declare their fields
under `configValues`, and the runtime hands a service a dictionary whose framework
keys are prefixed — but a *built-in* service's parameters sit in the instance's
config beside the framework's, so a new one named `appList` would overwrite the
user's blacklist.

This is cheap and it runs over the source, so a collision is found while the
service is being written rather than after a user's list goes missing.
"""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# Keys the framework stores in an instance's config. Anything a service also uses
# is a collision.
FRAMEWORK_KEYS = set()
consts = (ROOT / "Sources/Core/PusherConstants.swift").read_text()
for m in re.finditer(r'public static let \w+ = "([^"]+)"', consts):
    FRAMEWORK_KEYS.add(m.group(1))
# These are handed to services on purpose — `devices` and `sounds` are how the
# payload options reach a service, and `includeIcon` and friends are its
# parameters, not the framework's own bookkeeping.
FOR_SERVICES = {
    "devices", "sounds", "includeIcon", "includeImage", "curateData",
    "scriptStorage", "url", "dateFormat", "imageMaxWidth", "imageMaxHeight",
    "imageShrinkFactor", "enabled", "eventName", "serverURL", "key", "token",
    "user", "corpid", "corpsecret", "agentID", "touser", "dbName", "method",
    "paramName", "bodyType", "authenticationMethod", "id", "name", "type",
    "config", "configValues",
}

collisions = []
for path in sorted((ROOT / "Sources/Core/Services").glob("*.swift")):
    text = path.read_text()
    for m in re.finditer(r'static let \w+ = "([^"]+)"', text):
        key = m.group(1)
        if key in FRAMEWORK_KEYS and key not in FOR_SERVICES:
            collisions.append(f"{path.name}: {key}")

if collisions:
    print("Service parameter names that collide with framework keys:")
    for c in collisions:
        print("  " + c)
    sys.exit(1)

print(f"no collisions across {len(list((ROOT / 'Sources/Core/Services').glob('*.swift')))} services")
