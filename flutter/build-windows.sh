#!/usr/bin/env bash
# Package a Flutter app for Windows x64 on Linux. See README.md.
#
# Debug (JIT) build like build-macos.sh: there is no Linux gen_snapshot for
# Windows, so the debug flutter_windows.dll runs kernel_blob.bin. The runner
# (windows/runner and the Flutter C++ wrapper) is compiled with clang-cl and
# linked with lld-link against the MSVC CRT and Windows SDK that xwin
# downloads (https://github.com/Jake-Shadle/xwin), which means accepting the
# Microsoft license.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "$HERE/lib/common.sh"

usage() {
  cat << 'EOF'
usage: build-windows.sh --app-name NAME [options]

  --project DIR        Flutter project (default: .)
  --app-name NAME      NAME.exe, and the folder inside the zip
  --source PATH        runner source, repeatable (default: windows/runner/*.cpp
                       and windows/flutter/generated_plugin_registrant.cc)
  --lib NAME           extra Windows import library (e.g. windowscodecs), repeatable
  --rc PATH            resource script (default: windows/runner/Runner.rc)
  --manifest PATH      application manifest (default: windows/runner/runner.exe.manifest)
  --output PATH        zip to write (default: dist/NAME-windows-x64.zip)
  --cache DIR          download cache (default: $XTOOL_FLUTTER_CACHE or
                       ~/.cache/xtool-flutter)
  --flutter-arg ARG    extra argument for `flutter build bundle`, repeatable

Tools: clang-cl, llvm-rc and lld (lld-link) from LLVM; override with CLANG_CL,
LLVM_RC and LLD. Without an lld-link, xtool's ld64.lld is used (lld picks its
flavor from the program name).
EOF
}

PROJECT="."
APP_NAME=""
SOURCES=()
LIBS=()
RC=""
MANIFEST=""
OUTPUT=""
CACHE_ROOT="${XTOOL_FLUTTER_CACHE:-$HOME/.cache/xtool-flutter}"
FLUTTER_BUILD_ARGS=()
while (($#)); do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --source) SOURCES+=("$2"); shift 2 ;;
    --lib) LIBS+=("${2%.lib}"); shift 2 ;;
    --rc) RC="$2"; shift 2 ;;
    --manifest) MANIFEST="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --cache) CACHE_ROOT="$2"; shift 2 ;;
    --flutter-arg) FLUTTER_BUILD_ARGS+=("$2"); shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option $1" ;;
  esac
done
[[ -n "$APP_NAME" ]] || { usage >&2; die "missing --app-name"; }
PROJECT="$(cd "$PROJECT" && pwd)"
abs() { [[ "$1" = /* ]] && echo "$1" || echo "$PROJECT/$1"; }
RC="$(abs "${RC:-windows/runner/Runner.rc}")"
MANIFEST="$(abs "${MANIFEST:-windows/runner/runner.exe.manifest}")"
OUTPUT="$(abs "${OUTPUT:-dist/${APP_NAME}-windows-x64.zip}")"
if ((${#SOURCES[@]} == 0)); then
  SOURCES=("$PROJECT"/windows/runner/*.cpp "$PROJECT/windows/flutter/generated_plugin_registrant.cc")
fi
for i in "${!SOURCES[@]}"; do SOURCES[i]="$(abs "${SOURCES[i]}")"; done

# ------------------------------------------------------------------ checks

pick() { for t in "$@"; do command -v "$t" && return 0; done; return 1; }
CLANG_CL="${CLANG_CL:-$(pick clang-cl clang-cl-21 clang-cl-20 clang-cl-19 clang-cl-18 || true)}"
LLVM_RC="${LLVM_RC:-$(pick llvm-rc llvm-rc-21 llvm-rc-20 llvm-rc-19 llvm-rc-18 || true)}"
LLD="${LLD:-$(pick lld-link lld-link-21 lld-link-20 lld-link-19 lld-link-18 || true)}"
if [[ -z "$LLD" && -x "${XTOOL_SDK_BUNDLE:-/opt/xtool/darwin.xtoolsdk}/toolset/bin/orig/ld64.lld" ]]; then
  LLD="${XTOOL_SDK_BUNDLE:-/opt/xtool/darwin.xtoolsdk}/toolset/bin/orig/ld64.lld"
fi
[[ -n "$CLANG_CL" ]] || die "clang-cl not found (install clang, or set CLANG_CL)"
[[ -n "$LLVM_RC" ]] || die "llvm-rc not found (install llvm, or set LLVM_RC)"
[[ -n "$LLD" ]] || die "lld-link not found (install lld, or set LLD)"
for f in "${SOURCES[@]}" "$RC" "$MANIFEST"; do [[ -f "$f" ]] || die "not found: $f"; done

# Plugins with C++ code (FLUTTER_PLUGIN_LIST) cannot be built here. FFI
# plugins built by CMake are left out: package them yourself if the app
# needs them on Windows.
PLUGINS_CMAKE="$PROJECT/windows/flutter/generated_plugins.cmake"
if [[ -f "$PLUGINS_CMAKE" ]]; then
  list_plugins() {
    sed -n "/list(APPEND $1/,/)/p" "$PLUGINS_CMAKE" | sed '1d;$d' | tr -d ' ' | grep -v '^$' || true
  }
  native="$(list_plugins FLUTTER_PLUGIN_LIST)"
  [[ -z "$native" ]] || die "plugins with native Windows code are not supported: $(echo $native)"
  ffi="$(list_plugins FLUTTER_FFI_PLUGIN_LIST)"
  [[ -z "$ffi" ]] || log "note: FFI plugins not packaged: $(echo $ffi)"
fi

XWIN_VERSION="0.10.0"
XWIN_DIR="$CACHE_ROOT/xwin"
XWIN="$XWIN_DIR/xwin-$XWIN_VERSION"
SYSROOT="$XWIN_DIR/sysroot"
mkdir -p "$XWIN_DIR"
if [[ ! -x "$XWIN" ]]; then
  log "download xwin $XWIN_VERSION"
  tmp="$(mktemp -d)"
  curl -fL --retry 3 -o "$tmp/xwin.tar.gz" \
    "https://github.com/Jake-Shadle/xwin/releases/download/${XWIN_VERSION}/xwin-${XWIN_VERSION}-x86_64-unknown-linux-musl.tar.gz"
  tar -xzf "$tmp/xwin.tar.gz" -C "$tmp"
  install -m 755 "$(find "$tmp" -type f -name xwin -print -quit)" "$XWIN"
  rm -rf "$tmp"
fi
if [[ ! -f "$SYSROOT/.done" ]]; then
  log "xwin: download the MSVC CRT and Windows SDK (accepting the Microsoft license)"
  rm -rf "$SYSROOT"
  "$XWIN" --accept-license --arch x86_64 --cache-dir "$XWIN_DIR/cache" splat --output "$SYSROOT"
  touch "$SYSROOT/.done"
fi

ENGINE="$(flutter_engine_version)"
CACHE="$CACHE_ROOT/flutter-engine/$ENGINE/windows"
fetch_engine_artifact "$CACHE" windows-x64-debug/windows-x64-flutter.zip flutter-debug.zip
fetch_engine_artifact "$CACHE" windows-x64/flutter-cpp-client-wrapper.zip cpp-client-wrapper.zip
fetch_engine_artifact "$CACHE" windows-x64/artifacts.zip artifacts.zip
read_pubspec_version
log "$APP_NAME $VERSION_NAME ($VERSION_CODE), engine $ENGINE"

WORK="$PROJECT/build/xtool-flutter-windows"
rm -rf "$WORK"
mkdir -p "$WORK/engine" "$WORK/wrapper" "$WORK/core" "$WORK/obj" "$WORK/shim"
unzip -q -o "$CACHE/flutter-debug.zip" -d "$WORK/engine"
unzip -q -o "$CACHE/cpp-client-wrapper.zip" -d "$WORK/wrapper"
unzip -q -o "$CACHE/artifacts.zip" vm_isolate_snapshot.bin isolate_snapshot.bin icudtl.dat -d "$WORK/core"
ENGINE_DIR="$WORK/engine"
WRAPPER="$WORK/wrapper/cpp_client_wrapper"
[[ -f "$ENGINE_DIR/flutter_windows.dll.lib" ]] || die "unexpected windows-x64-flutter.zip layout"

build_flutter_assets

# --------------------------------------------------------------- the runner

IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION_NAME"
DEFS=(
  /DUNICODE /D_UNICODE /DWIN32 /D_WINDOWS /DNOMINMAX
  "/DFLUTTER_VERSION=\"${VERSION_NAME}+${VERSION_CODE}\""
  "/DFLUTTER_VERSION_MAJOR=${MAJOR:-1}" "/DFLUTTER_VERSION_MINOR=${MINOR:-0}"
  "/DFLUTTER_VERSION_PATCH=${PATCH:-0}" "/DFLUTTER_VERSION_BUILD=${VERSION_CODE}"
)
CXXFLAGS=(
  --target=x86_64-pc-windows-msvc /std:c++17 /EHsc /MT /O2 /W3
  -Wno-unused-command-line-argument -Wno-microsoft-include
  /imsvc "$SYSROOT/crt/include"
  /imsvc "$SYSROOT/sdk/include/ucrt"
  /imsvc "$SYSROOT/sdk/include/um"
  /imsvc "$SYSROOT/sdk/include/shared"
  /imsvc "$SYSROOT/sdk/include/winrt"
  "${DEFS[@]}"
  /I "$ENGINE_DIR" /I "$WRAPPER/include" /I "$WRAPPER"
  /I "$PROJECT/windows" /I "$PROJECT/windows/runner"
)
# The C++ wrapper, as windows/flutter/CMakeLists.txt builds it.
for f in core_implementations standard_codec plugin_registrar flutter_engine flutter_view_controller; do
  SOURCES+=("$WRAPPER/$f.cc")
done
OBJS=()
for src in "${SOURCES[@]}"; do
  obj="$WORK/obj/$(basename "$src").obj"
  "$CLANG_CL" "${CXXFLAGS[@]}" /c "$src" "/Fo$obj"
  OBJS+=("$obj")
done

# Resources. llvm-rc takes a leading "/" for an option, so inputs are given
# relative; the template's Runner.rc names the icon with a backslash.
printf '#include <winresrc.h>\n' > "$WORK/shim/winres.h" # some SDKs only ship winresrc.h
RCINC=(/I "$SYSROOT/sdk/include/um" /I "$SYSROOT/sdk/include/shared" /I "$WORK/shim")
RC_DIR="$(dirname "$RC")"
sed 's#\\\\#/#g' "$RC" > "$RC_DIR/.xtool-flutter.rc"
(cd "$RC_DIR" && "$LLVM_RC" "${RCINC[@]}" "${DEFS[@]}" /FO "$WORK/app.res" .xtool-flutter.rc)
rm -f "$RC_DIR/.xtool-flutter.rc"
# The manifest as RT_MANIFEST 1, which lld-link links without mt.exe.
printf '1 24 "%s"\n' "$MANIFEST" > "$WORK/manifest.rc"
(cd "$WORK" && "$LLVM_RC" "${RCINC[@]}" /FO manifest.res manifest.rc)

ln -sf "$LLD" "$WORK/lld-link"
OUT="$WORK/$APP_NAME"
mkdir -p "$OUT/data"
LIB_ARGS=()
for lib in dwmapi user32 gdi32 kernel32 advapi32 shell32 ole32 "${LIBS[@]}"; do LIB_ARGS+=("$lib.lib"); done
"$WORK/lld-link" /nologo /subsystem:windows /machine:x64 /entry:wWinMainCRTStartup \
  "/out:$OUT/$APP_NAME.exe" "${OBJS[@]}" "$WORK/app.res" "$WORK/manifest.res" \
  "/libpath:$SYSROOT/crt/lib/x86_64" \
  "/libpath:$SYSROOT/sdk/lib/um/x86_64" \
  "/libpath:$SYSROOT/sdk/lib/ucrt/x86_64" \
  "$ENGINE_DIR/flutter_windows.dll.lib" "${LIB_ARGS[@]}"

# ------------------------------------------------------------------ bundle

cp "$ENGINE_DIR/flutter_windows.dll" "$OUT/"
cp "$WORK/core/icudtl.dat" "$OUT/data/"
cp -a "$PROJECT/build/flutter_assets" "$OUT/data/flutter_assets"
# vm_isolate_snapshot.bin is empty for Windows; the engine expects that.
cp "$WORK/core/vm_isolate_snapshot.bin" "$OUT/data/flutter_assets/vm_snapshot_data"
cp "$WORK/core/isolate_snapshot.bin" "$OUT/data/flutter_assets/isolate_snapshot_data"

mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
(cd "$WORK" && zip -q -r "$OUTPUT" "$APP_NAME")
log "wrote $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
