# Shared helpers of build-macos.sh and build-windows.sh (sourced, not run).

die() {
  echo "error: $*" >&2
  exit 1
}

log() {
  echo "==> $*" >&2
}

# Engine revision of the flutter on PATH; every artifact must match it, or
# the engine rejects kernel_blob.bin ("Invalid kernel binary format version").
flutter_engine_version() {
  local flutter_bin
  flutter_bin="$(command -v flutter)" || die "flutter is not on PATH"
  flutter_bin="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$flutter_bin")"
  tr -d '[:space:]' < "$(dirname "$flutter_bin")/internal/engine.version"
}

# fetch <cache dir> <path under flutter_infra_release/flutter/ENGINE/> <file name>
# Downloads once per engine revision.
fetch_engine_artifact() {
  local dir="$1" remote="$2" name="$3"
  mkdir -p "$dir"
  if [[ ! -f "$dir/$name" ]]; then
    log "download $remote"
    curl -fL --retry 3 -o "$dir/$name.part" \
      "${FLUTTER_STORAGE_BASE_URL:-https://storage.googleapis.com}/flutter_infra_release/flutter/${ENGINE}/${remote}"
    mv "$dir/$name.part" "$dir/$name"
  fi
}

# Sets VERSION_NAME (1.2.3) and VERSION_CODE (4) from pubspec's "version: 1.2.3+4".
read_pubspec_version() {
  local version
  version="$(sed -n 's/^version:[[:space:]]*\([^[:space:]#]*\).*/\1/p' "$PROJECT/pubspec.yaml" | head -1)"
  version="${version:-1.0.0+1}"
  VERSION_NAME="${version%%+*}"
  VERSION_CODE="${version#*+}"
  [[ "$VERSION_CODE" == "$version" ]] && VERSION_CODE=1
  return 0
}

# Prints the root of a package resolved in .dart_tool/package_config.json,
# or nothing when the app does not depend on it.
package_root() {
  python3 - "$PROJECT/.dart_tool/package_config.json" "$1" << 'PY'
import json, sys
from pathlib import Path
from urllib.parse import unquote, urlparse

config_path, name = sys.argv[1], sys.argv[2]
config = json.load(open(config_path))
for pkg in config["packages"]:
    if pkg["name"] != name:
        continue
    uri = pkg["rootUri"]
    if uri.startswith("file://"):
        print(unquote(urlparse(uri).path))
    else:
        print((Path(config_path).parent / uri).resolve())
    break
PY
}

# Debug (JIT) bundle: kernel_blob.bin plus the core snapshots of the target
# engine (the ones flutter build bundle copies are the host's).
build_flutter_assets() {
  (cd "$PROJECT" && flutter pub get && flutter build bundle --debug "${FLUTTER_BUILD_ARGS[@]}")
  test -f "$PROJECT/build/flutter_assets/kernel_blob.bin" ||
    die "flutter build bundle did not produce kernel_blob.bin"
}
