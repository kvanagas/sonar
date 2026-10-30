#!/bin/bash
# Builds a notarized Sonar-<version>.dmg and its Sparkle appcast.xml in build/release.
# Attach both to the GitHub release v<version>; installed copies find the update
# through releases/latest/download/appcast.xml.
#
# Needs: xcodegen, a "Developer ID Application" certificate in the keychain,
# notarytool credentials saved under $NOTARY_PROFILE (default "sonar-mac"):
#   xcrun notarytool store-credentials sonar-mac --apple-id <email> --team-id <team>
# and the Sparkle signing key in the keychain under the account "sonar"
# (its public half is SUPublicEDKey in project.yml).
set -euo pipefail

cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-sonar-mac}"
REPO=kvanagas/sonar
TEAM_ID=$(awk '/DEVELOPMENT_TEAM:/ { print $2; exit }' project.yml)
VERSION=$(awk -F'"' '/MARKETING_VERSION:/ { print $2; exit }' project.yml)
OUT=build/release
ARCHIVE="$OUT/Sonar.xcarchive"
APP="$OUT/export/Sonar.app"
DMG="$OUT/Sonar-$VERSION.dmg"
DERIVED=build/DerivedData
SPARKLE_BIN="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin"

step() { printf '\n==> %s\n' "$1"; }

notarize() {
    xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h \
        | tee "$OUT/notary.log"
    # --wait exits 0 even when Apple rejects the upload.
    if ! grep -q 'status: Accepted' "$OUT/notary.log"; then
        id=$(awk '/^  id:/ { print $2; exit }' "$OUT/notary.log")
        echo "Notarization failed. Details: xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE" >&2
        exit 1
    fi
}

rm -rf "$OUT"
mkdir -p "$OUT"

xcodegen generate --quiet

step "Running tests"
xcodebuild test -quiet \
    -project Sonar.xcodeproj -scheme Sonar -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED"

step "Archiving Sonar $VERSION"
xcodebuild archive -quiet \
    -project Sonar.xcodeproj -scheme Sonar -configuration Release \
    -archivePath "$ARCHIVE" -derivedDataPath "$DERIVED" -allowProvisioningUpdates

step "Exporting with Developer ID"
cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -quiet \
    -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist "$OUT/ExportOptions.plist" -allowProvisioningUpdates
codesign --verify --strict --deep "$APP"

# The app is notarized and stapled on its own first, so it still opens
# offline after being dragged out of the disk image.
step "Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Sonar.zip"
notarize "$OUT/Sonar.zip"
xcrun stapler staple "$APP"

step "Building $DMG"
mkdir "$OUT/dmg"
cp -R "$APP" "$OUT/dmg/"
ln -s /Applications "$OUT/dmg/Applications"
hdiutil create -quiet -volname "Sonar" -srcfolder "$OUT/dmg" -format UDZO "$DMG"
codesign --sign "Developer ID Application" --timestamp "$DMG"

step "Notarizing the disk image"
notarize "$DMG"
xcrun stapler staple "$DMG"

step "Checking Gatekeeper"
spctl --assess --type open --context context:primary-signature -v "$DMG"
spctl --assess --type execute -v "$APP"

step "Writing the update feed"
mkdir "$OUT/appcast"
cp "$DMG" "$OUT/appcast/"
"$SPARKLE_BIN/generate_appcast" --account sonar \
    --download-url-prefix "https://github.com/$REPO/releases/download/v$VERSION/" \
    --link "https://github.com/$REPO" \
    "$OUT/appcast"
mv "$OUT/appcast/appcast.xml" "$OUT/appcast.xml"

shasum -a 256 "$DMG" | tee "$DMG.sha256"
printf '\nDone: %s and %s/appcast.xml\n' "$DMG" "$OUT"
