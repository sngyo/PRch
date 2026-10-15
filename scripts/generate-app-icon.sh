#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
source_image="$project_root/Resources/Brand/AppIcon.png"
swift "$project_root/scripts/render-app-icon.swift" "$project_root/Resources/Brand/AppIcon.svg" "$source_image"
iconset_directory="$(mktemp -d "${TMPDIR:-/tmp}/prch-icon.XXXXXX")"
trap 'rm -rf "$iconset_directory"' EXIT
mkdir -p "$iconset_directory/AppIcon.iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source_image" --out "$iconset_directory/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$source_image" --out "$iconset_directory/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset_directory/AppIcon.iconset" -o "$project_root/Resources/AppIcon.icns"
echo "Built: $project_root/Resources/AppIcon.icns"
