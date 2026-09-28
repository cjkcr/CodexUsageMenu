#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"

./build.sh

app="$PWD/build/Codex Usage Menu.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
dist="$PWD/dist"
stage="$PWD/build/package-stage"
mkdir -p "$dist"
rm -rf "$stage"
mkdir -p "$stage/dmg" "$stage/pkg" "$stage/installer-resources" "$stage/scripts"

# A local signature seals the app bundle. Public distribution requires a
# Developer ID certificate and notarization, which are not available here.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

ditto --noextattr --norsrc --noqtn "$app" "$stage/pkg/Codex Usage Menu.app"
cat > "$stage/scripts/preinstall" <<'SCRIPT'
#!/bin/sh
# Stop the old in-memory version before replacing the application bundle.
console_user=$(/usr/bin/stat -f %Su /dev/console)
if [ "$console_user" != root ] && [ "$console_user" != loginwindow ]; then
  console_uid=$(/usr/bin/id -u "$console_user")
  /usr/bin/pkill -u "$console_uid" -x CodexUsageMenu 2>/dev/null || true
fi
# Versions before 1.0.6 used an app bundle name without spaces.
/bin/rm -rf "/Applications/CodexUsageMenu.app"
exit 0
SCRIPT
cat > "$stage/scripts/postinstall" <<'SCRIPT'
#!/bin/sh
# Open the installed app in the signed-in user's desktop session so installation
# has a visible result and the user does not need to search for the app.
console_user=$(/usr/bin/stat -f %Su /dev/console)
if [ "$console_user" != root ] && [ "$console_user" != loginwindow ]; then
  console_uid=$(/usr/bin/id -u "$console_user")
  /bin/launchctl asuser "$console_uid" /usr/bin/open "/Applications/Codex Usage Menu.app" \
    >/dev/null 2>&1 || true
fi
exit 0
SCRIPT
chmod 755 "$stage/scripts/preinstall"
chmod 755 "$stage/scripts/postinstall"
COPYFILE_DISABLE=1 pkgbuild --root "$stage/pkg" --scripts "$stage/scripts" --install-location /Applications \
  --identifier local.codex.usage-menu --version "$version" \
  "$stage/CodexUsageMenu-component.pkg"

cat > "$stage/installer-resources/welcome.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<h2>安装 Codex Usage Menu</h2>
<p>应用固定安装到系统“应用程序”文件夹，因此不需要选择安装位置。更新前请先退出正在运行的旧版本。</p>
<p>安装完成后，Codex Usage Menu 会自动打开，用量窗口和菜单栏图标会同时出现。</p>
HTML
cat > "$stage/installer-resources/conclusion.html" <<'HTML'
<!doctype html><html lang="zh-CN"><meta charset="utf-8">
<h2>安装完成</h2>
<p>Codex Usage Menu 已安装到“应用程序/Codex Usage Menu.app”，并会自动打开。窗口会显示当前版本和用量；关闭窗口后应用继续在菜单栏运行。如需恢复窗口，请从“应用程序”再次打开。</p>
<p>如果菜单栏图标被刘海或其他图标遮挡，可在应用窗口中选择“仅图标”，并释放右侧菜单栏空间。</p>
HTML
cat > "$stage/distribution.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>Codex Usage Menu</title>
  <options customize="never" require-scripts="false"/>
  <domains enable_anywhere="false" enable_currentUserHome="false" enable_localSystem="true"/>
  <welcome file="welcome.html" mime-type="text/html"/>
  <conclusion file="conclusion.html" mime-type="text/html"/>
  <choices-outline><line choice="default"/></choices-outline>
  <choice id="default" visible="false"><pkg-ref id="local.codex.usage-menu"/></choice>
  <pkg-ref id="local.codex.usage-menu" version="$version">CodexUsageMenu-component.pkg</pkg-ref>
</installer-gui-script>
XML
productbuild --distribution "$stage/distribution.xml" \
  --resources "$stage/installer-resources" --package-path "$stage" \
  "$dist/CodexUsageMenu-$version.pkg"

cp "$dist/CodexUsageMenu-$version.pkg" "$stage/dmg/安装 Codex Usage Menu.pkg"
cat > "$stage/dmg/安装说明.txt" <<'TEXT'
双击“安装 Codex Usage Menu.pkg”，按安装器提示完成安装。
安装完成后，从“应用程序”打开 Codex Usage Menu。
打开 DMG 只会显示安装文件，不会自动安装。
TEXT
hdiutil create -volname 'Codex Usage Menu' -srcfolder "$stage/dmg" \
  -ov -format UDZO "$dist/CodexUsageMenu-$version.dmg"

echo "$dist/CodexUsageMenu-$version.dmg"
echo "$dist/CodexUsageMenu-$version.pkg"
