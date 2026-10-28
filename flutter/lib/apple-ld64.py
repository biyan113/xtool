#!/usr/bin/env python3
"""Translate clang's Darwin linker flags for xtool's ld64.lld."""
import os
import sys

LD = os.environ.get(
    "APPLE_LD64",
    "/opt/xtool/darwin.xtoolsdk/toolset/bin/orig/ld64.lld",
)

args = sys.argv[1:]
out = []
i = 0
has_platform = False
has_arch = False
minver = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "12.0")
sdkver = os.environ.get("APPLE_SDK_VERSION", "27.0")
while i < len(args):
    a = args[i]
    if a == "-platform_version":
        has_platform = True
        out.extend(args[i : i + 4])
        i += 4
        continue
    if a == "-macosx_version_min":
        minver = args[i + 1]
        i += 2
        continue
    if a.startswith("-macosx_version_min"):
        minver = a[len("-macosx_version_min") :].lstrip("=")
        i += 1
        continue
    if a == "-arch":
        has_arch = True
        out.extend([a, args[i + 1]])
        i += 2
        continue
    out.append(a)
    i += 1
if not has_arch:
    out = ["-arch", "arm64"] + out
if not has_platform:
    out = ["-platform_version", "macos", minver, sdkver] + out
os.execv(LD, [LD] + out)
