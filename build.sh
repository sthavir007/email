#!/bin/zsh
# Builds ~/Applications/email.app (local only)
set -e
cd "$(dirname "$0")"
swift build -c release
APP=~/Applications/email.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/email "$APP/Contents/MacOS/email"
if [ ! -f .build/AppIcon.icns ]; then
  swiftc -target arm64-apple-macos26.0 make-icon.swift -o .build/make-icon
  .build/make-icon .build/AppIcon.iconset && iconutil -c icns .build/AppIcon.iconset -o .build/AppIcon.icns
fi
cp .build/AppIcon.icns "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.sthavir.email</string>
  <key>CFBundleName</key><string>email</string>
  <key>CFBundleDisplayName</key><string>email</string>
  <key>CFBundleExecutable</key><string>email</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>UTExportedTypeDeclarations</key><array><dict>
    <key>UTTypeIdentifier</key><string>com.sthavir.email.mail</string>
    <key>UTTypeDescription</key><string>email in the email app</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string></array>
  </dict></array>
</dict></plist>
PLIST
# Apple Development cert keeps keychain access stable across rebuilds; ad-hoc otherwise
SIGN_ID=$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | awk '{print $2}')
codesign --force -s "${SIGN_ID:--}" "$APP"
echo "built $APP"
