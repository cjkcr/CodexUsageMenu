#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
app="${PWD}/build/CodexUsageMenu.app"
mkdir -p "$app/Contents/MacOS"
mkdir -p "$app/Contents/Resources"
mkdir -p build/cache
sdk_args=()
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
  sdk_args=(-sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk)
fi
CLANG_MODULE_CACHE_PATH="$PWD/build/cache" swiftc -parse-as-library -swift-version 5 -O \
  "${sdk_args[@]}" -framework AppKit Sources/CodexUsageMenu/main.swift \
  -o "$app/Contents/MacOS/CodexUsageMenu"
cp Assets/codex-mark.png "$app/Contents/Resources/codex-mark.png"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.codex.usage-menu</string>
  <key>CFBundleName</key><string>Codex Usage Menu</string>
  <key>CFBundleExecutable</key><string>CodexUsageMenu</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "$app"
