#!/usr/bin/env bash
# Package a Flutter app for macOS (arm64) on Linux. See README.md.
#
# Debug (JIT) build: Flutter ships no Linux gen_snapshot that targets macOS
# (the Android one writes "arm64 android compressed-pointers" snapshots,
# which the macOS engine rejects), so the debug FlutterMacOS.framework runs
# kernel_blob.bin. The Swift runner is compiled with the Darwin SDK that
# `xtool setup` installs and linked with its ld64.lld.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

usage() {
  cat << 'EOF'
usage: build-macos.sh --app-name NAME --bundle-id ID --nib PATH [options]

  --project DIR          Flutter project (default: .)
  --app-name NAME        NAME.app and its executable
  --bundle-id ID         CFBundleIdentifier
  --nib PATH             compiled MainMenu.nib (from Contents/Resources/Base.lproj
                         of a Mac build of the same app)
  --swift-module NAME    module the nib names its classes with (default: app name)
  --icon PATH            AppIcon.icns
  --swift-source PATH    runner source, repeatable (default: macos/Runner/*.swift
                         and macos/Flutter/GeneratedPluginRegistrant.swift)
  --framework NAME       extra system framework to link, repeatable
  --plist-entries PATH   XML <key>/<value> pairs added to Info.plist
  --min-macos VERSION    minimum macOS (default: 12.0)
  --output PATH          zip to write (default: dist/NAME-macos-arm64.zip)
  --cache DIR            download cache (default: $XTOOL_FLUTTER_CACHE or
                         ~/.cache/xtool-flutter)
  --flutter-arg ARG      extra argument for `flutter build bundle`, repeatable
EOF
}

PROJECT="."
APP_NAME=""
BUNDLE_ID=""
NIB=""
SWIFT_MODULE=""
ICON=""
SWIFT_SOURCES=()
FRAMEWORKS=()
PLIST_ENTRIES=""
MIN_OS="12.0"
OUTPUT=""
CACHE_ROOT="${XTOOL_FLUTTER_CACHE:-$HOME/.cache/xtool-flutter}"
FLUTTER_BUILD_ARGS=()
while (($#)); do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --nib) NIB="$2"; shift 2 ;;
    --swift-module) SWIFT_MODULE="$2"; shift 2 ;;
    --icon) ICON="$2"; shift 2 ;;
    --swift-source) SWIFT_SOURCES+=("$2"); shift 2 ;;
    --framework) FRAMEWORKS+=("$2"); shift 2 ;;
    --plist-entries) PLIST_ENTRIES="$2"; shift 2 ;;
    --min-macos) MIN_OS="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --cache) CACHE_ROOT="$2"; shift 2 ;;
    --flutter-arg) FLUTTER_BUILD_ARGS+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option $1" ;;
  esac
done
[[ -n "$APP_NAME" && -n "$BUNDLE_ID" && -n "$NIB" ]] || { usage >&2; die "missing a required option"; }
PROJECT="$(cd "$PROJECT" && pwd)"
abs() { [[ "$1" = /* ]] && echo "$1" || echo "$PROJECT/$1"; }
NIB="$(abs "$NIB")"
[[ -n "$ICON" ]] && ICON="$(abs "$ICON")"
[[ -n "$PLIST_ENTRIES" ]] && PLIST_ENTRIES="$(abs "$PLIST_ENTRIES")"
SWIFT_MODULE="${SWIFT_MODULE:-$APP_NAME}"
OUTPUT="$(abs "${OUTPUT:-dist/${APP_NAME}-macos-arm64.zip}")"
if ((${#SWIFT_SOURCES[@]} == 0)); then
  SWIFT_SOURCES=("$PROJECT"/macos/Runner/*.swift "$PROJECT/macos/Flutter/GeneratedPluginRegistrant.swift")
fi
for i in "${!SWIFT_SOURCES[@]}"; do SWIFT_SOURCES[i]="$(abs "${SWIFT_SOURCES[i]}")"; done

# ------------------------------------------------------------------ checks

SDK_BUNDLE="${XTOOL_SDK_BUNDLE:-/opt/xtool/darwin.xtoolsdk}"
SDK="$SDK_BUNDLE/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
TC="$SDK_BUNDLE/Developer/Toolchains/XcodeDefault.xctoolchain"
LD64="$SDK_BUNDLE/toolset/bin/orig/ld64.lld"
CLANG="${CLANG:-$(command -v clang-19 || command -v clang)}"
[[ -d "$SDK" ]] || die "Darwin SDK not found at $SDK (run 'xtool setup', or set XTOOL_SDK_BUNDLE)"
[[ -x "$LD64" ]] || die "ld64.lld not found at $LD64"
command -v swiftc > /dev/null || die "swiftc is not on PATH"
[[ -x "$CLANG" ]] || die "clang not found (set CLANG)"
[[ -f "$NIB" ]] || die "nib not found: $NIB"
for f in "${SWIFT_SOURCES[@]}"; do [[ -f "$f" ]] || die "swift source not found: $f"; done

# The nib refers to its classes by module: _TtC<len><module>11AppDelegate.
# With another module name the app starts without delegate and window.
if ! grep -q "_TtC${#SWIFT_MODULE}${SWIFT_MODULE}11AppDelegate" "$NIB"; then
  found="$(grep -ao '_TtC[0-9]*[A-Za-z_][A-Za-z0-9_]*11AppDelegate' "$NIB" | head -1 || true)"
  die "the nib's AppDelegate is '${found:-?}', not module '$SWIFT_MODULE' (pass --swift-module)"
fi

# Plugins with their own Swift/Objective-C code cannot be built here.
REGISTRANT="$PROJECT/macos/Flutter/GeneratedPluginRegistrant.swift"
if [[ -f "$REGISTRANT" ]]; then
  native_plugins="$(sed -n 's/^import[[:space:]]\{1,\}\([A-Za-z0-9_]*\).*/\1/p' "$REGISTRANT" |
    grep -vxE 'FlutterMacOS|Foundation' || true)"
  [[ -z "$native_plugins" ]] || die "plugins with native macOS code are not supported: $native_plugins"
fi

export MACOSX_DEPLOYMENT_TARGET="$MIN_OS"
export APPLE_LD64="$LD64"
export APPLE_SDK_VERSION="${APPLE_SDK_VERSION:-$(sed -n 's/.*"Version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$SDK/SDKSettings.json" 2>/dev/null | head -1)}"
APPLE_SDK_VERSION="${APPLE_SDK_VERSION:-15.0}"
# Let SwiftPM-aware tools find the SDK without copying it.
mkdir -p "$HOME/.swiftpm/swift-sdks"
ln -sfn "$SDK_BUNDLE" "$HOME/.swiftpm/swift-sdks/darwin.artifactbundle"
export XCODE_EXTRA_PLATFORM_FOLDERS="$SDK_BUNDLE/Developer/Platforms"

ENGINE="$(flutter_engine_version)"
CACHE="$CACHE_ROOT/flutter-engine/$ENGINE/macos"
fetch_engine_artifact "$CACHE" darwin-x64/FlutterMacOS.framework.zip FlutterMacOS.framework.zip
fetch_engine_artifact "$CACHE" darwin-x64/artifacts.zip artifacts.zip
read_pubspec_version
log "$APP_NAME $VERSION_NAME ($VERSION_CODE), engine $ENGINE, macOS SDK $APPLE_SDK_VERSION"

WORK="$PROJECT/build/xtool-flutter-macos"
rm -rf "$WORK"
mkdir -p "$WORK/fw" "$WORK/core" "$WORK/objc"

# ------------------------------------------------------- Flutter frameworks

# The download is a zip that holds FlutterMacOS.framework.zip.
unzip -q -o "$CACHE/FlutterMacOS.framework.zip" -d "$WORK/fw"
FLUTTER_FW="$WORK/FlutterMacOS.framework"
mkdir -p "$FLUTTER_FW"
unzip -q -o "$WORK/fw/FlutterMacOS.framework.zip" -d "$FLUTTER_FW"
[[ -f "$FLUTTER_FW/Versions/A/FlutterMacOS" ]] || die "unexpected FlutterMacOS.framework.zip layout"
unzip -q -o "$CACHE/artifacts.zip" vm_isolate_snapshot.bin isolate_snapshot.bin -d "$WORK/core"

build_flutter_assets
APP_FW="$WORK/App.framework"
ASSETS="$APP_FW/Versions/A/Resources/flutter_assets"
mkdir -p "$APP_FW/Versions/A/Resources"
cp -a "$PROJECT/build/flutter_assets" "$ASSETS"
cp "$WORK/core/vm_isolate_snapshot.bin" "$ASSETS/vm_snapshot_data"
cp "$WORK/core/isolate_snapshot.bin" "$ASSETS/isolate_snapshot_data"

framework_plist() { # executable identifier
  cat << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$1</string>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleName</key><string>$1</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>MinimumOSVersion</key><string>$MIN_OS</string>
</dict></plist>
EOF
}

finish_framework() { # dir executable
  ln -s A "$1/Versions/Current"
  ln -s "Versions/Current/$2" "$1/$2"
  ln -s Versions/Current/Resources "$1/Resources"
}

DARWIN_CC=("$CLANG" --target="arm64-apple-macos${MIN_OS}" -isysroot "$SDK" -mmacosx-version-min="$MIN_OS")
DARWIN_LD=(-fuse-ld="$HERE/lib/apple-ld64.py")

# In debug mode App is only the bundle that carries flutter_assets.
echo 'void xtool_flutter_app_stub(void) {}' > "$WORK/app_stub.c"
"${DARWIN_CC[@]}" "${DARWIN_LD[@]}" -dynamiclib -install_name '@rpath/App.framework/App' \
  -o "$APP_FW/Versions/A/App" "$WORK/app_stub.c"
framework_plist App io.flutter.flutter.app > "$APP_FW/Versions/A/Resources/Info.plist"
finish_framework "$APP_FW" App

# package:objective_c (path_provider, ffigen bindings) ships its dylib as a
# native asset built by a hook; build it the same way: every .c/.m under src/.
EXTRA_FWS=()
OBJC_ROOT="$(package_root objective_c)"
if [[ -n "$OBJC_ROOT" ]]; then
  OBJC_SRC="$OBJC_ROOT/src"
  OBJC_FW="$WORK/objective_c.framework"
  mkdir -p "$OBJC_FW/Versions/A/Resources"
  objs=()
  while IFS= read -r src; do
    rel="${src#"$OBJC_SRC"/}"
    obj="$WORK/objc/${rel//\//_}.o"
    extra=()
    [[ "$src" == *.m ]] && extra=(-x objective-c -fobjc-arc)
    "${DARWIN_CC[@]}" -fpic -I "$OBJC_SRC" -I "$OBJC_SRC/include" "${extra[@]}" -c -o "$obj" "$src"
    objs+=("$obj")
  done < <(find "$OBJC_SRC" -type f \( -name '*.c' -o -name '*.m' \) | sort)
  "${DARWIN_CC[@]}" "${DARWIN_LD[@]}" -dynamiclib -Wl,-undefined,dynamic_lookup \
    -install_name '@rpath/objective_c.framework/Versions/A/objective_c' \
    -framework Foundation -o "$OBJC_FW/Versions/A/objective_c" "${objs[@]}"
  framework_plist objective_c dev.dart.objective_c > "$OBJC_FW/Versions/A/Resources/Info.plist"
  finish_framework "$OBJC_FW" objective_c
  EXTRA_FWS+=("$OBJC_FW")
  python3 - "$ASSETS/NativeAssetsManifest.json" << 'PY'
import json, sys
json.dump({
  "format-version": [1, 0, 0],
  "native-assets": {
    "macos_arm64": {
      "package:objective_c/objective_c.dylib": ["absolute", "objective_c.framework/objective_c"]
    }
  }
}, open(sys.argv[1], "w"))
PY
fi

# --------------------------------------------------------------- the runner

# Swift's clang importer always uses <resource-dir>/clang. The Xcode
# toolchain's copy has no include/ (stdbool.h...), so point it at the clang
# that ships with this swiftc and keep the toolchain's Swift modules.
SWIFT_RES="$WORK/swift-resource"
mkdir -p "$SWIFT_RES"
for f in "$TC/usr/lib/swift"/*; do
  [[ "$(basename "$f")" == clang ]] || ln -s "$f" "$SWIFT_RES/$(basename "$f")"
done
SWIFT_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$(command -v swiftc)")"
CLANG_RES="$("$(dirname "$SWIFT_BIN")/clang" -print-resource-dir)"
[[ -f "$CLANG_RES/include/stdbool.h" ]] || die "no clang headers in $CLANG_RES"
ln -s "$CLANG_RES" "$SWIFT_RES/clang"

swiftc \
  -resource-dir "$SWIFT_RES" \
  -module-name "$SWIFT_MODULE" \
  -O -whole-module-optimization \
  -Xfrontend -enable-cross-import-overlays \
  -sdk "$SDK" \
  -target "arm64-apple-macosx${MIN_OS}" \
  -swift-version 5 \
  -F "$WORK" \
  -framework FlutterMacOS \
  -c -o "$WORK/runner.o" \
  "${SWIFT_SOURCES[@]}"

# Linux swift-autolink-extract cannot read Mach-O: name the Swift runtime
# libraries explicitly (those the SDK has).
LIBFLAGS=()
for lib in swiftCore swiftFoundation swiftAppKit swiftCoreFoundation swiftObjectiveC \
  swiftDarwin swiftDispatch swiftUniformTypeIdentifiers swiftos swiftXPC swiftCoreImage \
  swiftQuartzCore swiftMetal swiftOSLog swiftIOKit swiftCoreAudio swiftSpatial swiftsimd; do
  [[ -e "$SDK/usr/lib/swift/lib${lib}.tbd" ]] && LIBFLAGS+=("-l$lib")
done
FWFLAGS=()
for fw in Foundation AppKit CoreFoundation "${FRAMEWORKS[@]}"; do FWFLAGS+=(-framework "$fw"); done

"$LD64" -arch arm64 -platform_version macos "$MIN_OS" "$APPLE_SDK_VERSION" \
  -syslibroot "$SDK" \
  -o "$WORK/$APP_NAME" "$WORK/runner.o" \
  -L "$SDK/usr/lib/swift" -L "$TC/usr/lib/swift/macosx" \
  "${LIBFLAGS[@]}" -lobjc -lSystem \
  "${FWFLAGS[@]}" -F "$WORK" -framework FlutterMacOS \
  -rpath @executable_path/../Frameworks

# ------------------------------------------------------------------ bundle

APP="$WORK/$APP_NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Base.lproj" "$APP/Contents/Frameworks"
cp "$WORK/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp -a "$NIB" "$APP/Contents/Resources/Base.lproj/MainMenu.nib"
ICON_KEYS=""
if [[ -n "$ICON" ]]; then
  cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEYS="<key>CFBundleIconFile</key><string>AppIcon</string><key>CFBundleIconName</key><string>AppIcon</string>"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
cat > "$APP/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  $ICON_KEYS
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION_NAME</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>CFBundleVersion</key><string>$VERSION_CODE</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_OS</string>
  <key>NSMainNibFile</key><string>MainMenu</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
$([[ -n "$PLIST_ENTRIES" ]] && cat "$PLIST_ENTRIES")
</dict></plist>
EOF
cp -a "$FLUTTER_FW" "$APP/Contents/Frameworks/FlutterMacOS.framework"
cp -a "$APP_FW" "$APP/Contents/Frameworks/App.framework"
for fw in "${EXTRA_FWS[@]}"; do cp -a "$fw" "$APP/Contents/Frameworks/"; done

# Ad-hoc signature without entitlements: a sandboxed ad-hoc app is killed
# by macOS, and the debug engine needs JIT, which the hardened runtime blocks.
RCODESIGN="$CACHE_ROOT/rcodesign-0.29.0"
if [[ ! -x "$RCODESIGN" ]]; then
  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "$tmp/rcodesign.tar.gz" \
    "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign/0.29.0/apple-codesign-0.29.0-x86_64-unknown-linux-musl.tar.gz"
  tar -xzf "$tmp/rcodesign.tar.gz" -C "$tmp"
  install -m 755 "$(find "$tmp" -type f -name rcodesign -print -quit)" "$RCODESIGN"
  rm -rf "$tmp"
fi
sign() { "$RCODESIGN" sign "$1" > "$WORK/rcodesign.log" 2>&1 || { cat "$WORK/rcodesign.log" >&2; die "signing $1 failed"; }; }
for fw in "$APP/Contents/Frameworks"/*.framework; do sign "$fw"; done
sign "$APP"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$WORK" && zip -q -r -y "$OUTPUT" "$APP_NAME.app")
log "wrote $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
