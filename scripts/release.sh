#!/bin/sh
set -eu
cd "$(dirname "$0")/.."

PROFILE="${1:?keychain profile name, see README}"
BUILD=build
APP="$BUILD/export/TrackpadSwitch.app"

rm -rf "$BUILD"
xcodegen generate
xcodebuild -project TrackpadSwitch.xcodeproj -scheme TrackpadSwitch -configuration Release \
  -onlyUsePackageVersionsFromResolvedFile archive -archivePath "$BUILD/TrackpadSwitch.xcarchive"
xcodebuild -exportArchive -archivePath "$BUILD/TrackpadSwitch.xcarchive" \
  -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$BUILD/export"

ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$PROFILE" --wait | tee "$BUILD/notary.log"
grep -q "status: Accepted" "$BUILD/notary.log"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
ZIP="TrackpadSwitch-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$BUILD/$ZIP"
(cd "$BUILD" && shasum -a 256 "$ZIP" > "$ZIP.sha256")
echo "$BUILD/$ZIP"
cat "$BUILD/$ZIP.sha256"
