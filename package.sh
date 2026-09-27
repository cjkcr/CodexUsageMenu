#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

./build.sh

app="$PWD/build/CodexUsageMenu.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
dist="$PWD/dist"
stage="$PWD/build/package-stage"
mkdir -p "$dist"
rm -rf "$stage"
mkdir -p "$stage/dmg" "$stage/pkg"

# A local signature seals the app bundle. Public distribution requires a
# Developer ID certificate and notarization, which are not available here.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

ditto --noextattr --norsrc --noqtn "$app" "$stage/dmg/CodexUsageMenu.app"
ln -s /Applications "$stage/dmg/Applications"
hdiutil create -volname 'Codex Usage Menu' -srcfolder "$stage/dmg" \
  -ov -format UDZO "$dist/CodexUsageMenu-$version.dmg"

ditto --noextattr --norsrc --noqtn "$app" "$stage/pkg/CodexUsageMenu.app"
COPYFILE_DISABLE=1 pkgbuild --root "$stage/pkg" --install-location /Applications \
  --identifier local.codex.usage-menu --version "$version" \
  "$dist/CodexUsageMenu-$version.pkg"

echo "$dist/CodexUsageMenu-$version.dmg"
echo "$dist/CodexUsageMenu-$version.pkg"
