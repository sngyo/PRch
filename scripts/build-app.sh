#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-release}"
case "$configuration" in debug|release) ;; *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;; esac
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
app_directory="$project_root/dist/PRch.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/PRch" "$app_directory/Contents/MacOS/PRch"
cp "$project_root/Resources/Info.plist" "$app_directory/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_directory/Contents/Resources/AppIcon.icns"
ditto "$binary_directory/PRch_PRch.bundle" "$app_directory/Contents/Resources/PRch_PRch.bundle"
codesign --force --sign - "$app_directory"
echo "Built: $app_directory"
