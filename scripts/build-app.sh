#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
usage() { echo "Usage: $0 [debug|release] [--install]" >&2; exit 2; }
configuration=release
install=false
for argument in "$@"; do
    case "$argument" in
        debug|release) configuration="$argument" ;;
        --install) install=true ;;
        *) usage ;;
    esac
done
swift build -c "$configuration"
binary_directory="$(swift build -c "$configuration" --show-bin-path)"
app_directory="$project_root/dist/PRch.app"
mkdir -p "$app_directory/Contents/MacOS" "$app_directory/Contents/Resources"
cp "$binary_directory/PRch" "$app_directory/Contents/MacOS/PRch"
cp "$project_root/Resources/Info.plist" "$app_directory/Contents/Info.plist"
cp "$project_root/Resources/AppIcon.icns" "$app_directory/Contents/Resources/AppIcon.icns"
ditto "$binary_directory/PRch_PRch.bundle" "$app_directory/Contents/Resources/PRch_PRch.bundle"
codesign --force --sign - "$app_directory"
# Reflect the completed build in Finder's app bundle modification date.
touch "$app_directory"
echo "Built: $app_directory"

$install || exit 0
# macOS removes menu bar items of apps running outside /Applications while a
# menu bar manager hides other items, so the everyday copy lives there.
installed_app="/Applications/PRch.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_directory/Contents/Info.plist")"
is_running() { [ "$(osascript -e "application id \"$bundle_id\" is running")" = true ]; }
if is_running; then
    osascript -e "tell application id \"$bundle_id\" to quit"
    for _ in $(seq 1 20); do is_running || break; sleep 0.5; done
    if is_running; then echo "PRch did not quit; install skipped." >&2; exit 1; fi
fi
rm -rf "$installed_app"
ditto "$app_directory" "$installed_app"
codesign --verify "$installed_app"
open "$installed_app"
echo "Installed and launched: $installed_app"
