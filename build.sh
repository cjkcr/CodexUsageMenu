#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
version="$(tr -d '\r\n' < VERSION)"
if [[ ! "$version" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
  echo "Invalid VERSION: $version" >&2
  exit 1
fi
app="${PWD}/build/CodexUsageMenu.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
mkdir -p build/cache
sdk_args=()
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk_args=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
for arch in arm64 x86_64; do
  CLANG_MODULE_CACHE_PATH="$PWD/build/cache" swiftc -parse-as-library -swift-version 5 -O \
    "${sdk_args[@]}" -target "${arch}-apple-macos13.0" -framework AppKit \
    Sources/CodexUsageMenu/main.swift -o "build/CodexUsageMenu-${arch}"
done
lipo -create build/CodexUsageMenu-arm64 build/CodexUsageMenu-x86_64 \
  -output "$app/Contents/MacOS/CodexUsageMenu"
cp Assets/codex-mark.png "$app/Contents/Resources/codex-mark.png"
iconset="$PWD/build/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Assets/app-icon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" Assets/app-icon.png \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns -o "$app/Contents/Resources/AppIcon.icns" "$iconset"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.codex.usage-menu</string>
  <key>CFBundleName</key><string>Codex Usage Menu</string>
  <key>CFBundleExecutable</key><string>CodexUsageMenu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "$app"
