#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="${1:-debug}"

case "$configuration" in
    debug|release) ;;
    *) printf 'Unsupported build configuration: %s\n' "$configuration" >&2; exit 1 ;;
esac

binary_directory="$(xcrun swift build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"
executable="$binary_directory/MindmapADE"

if [[ ! -x "$executable" ]]; then
    printf 'Build the app first with make build CONFIGURATION=%s.\n' "$configuration" >&2
    exit 1
fi

distribution_directory="$project_root/dist"
mkdir -p "$distribution_directory"
staging_directory="$(mktemp -d "$distribution_directory/.MindmapADE.XXXXXX")"
trap 'rm -rf "$staging_directory"' EXIT

staged_bundle="$staging_directory/MindmapADE.app"
mkdir -p "$staged_bundle/Contents/MacOS" "$staged_bundle/Contents/Resources"
install -m 755 "$executable" "$staged_bundle/Contents/MacOS/MindmapADE"
cp "$project_root/Resources/Info.plist" "$staged_bundle/Contents/Info.plist"
cp "$project_root/THIRD-PARTY-NOTICES.md" "$staged_bundle/Contents/Resources/"
plutil -lint "$staged_bundle/Contents/Info.plist"
codesign --force --sign "${CODE_SIGN_IDENTITY:--}" --timestamp=none "$staged_bundle"
codesign --verify --strict "$staged_bundle"

app_bundle="$distribution_directory/MindmapADE.app"
rm -rf "$app_bundle"
mv "$staged_bundle" "$app_bundle"
printf 'App bundle: %s\n' "$app_bundle"
