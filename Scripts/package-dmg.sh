#!/bin/zsh
# Builds build/Squish-<version>.dmg with an Applications shortcut.
#   Scripts/package-dmg.sh                                   ad-hoc signed, for local use
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=squish-notary Scripts/package-dmg.sh
set -euo pipefail
cd "${0:A:h}/.."

Scripts/bundle.sh
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
DMG=build/Squish-$VERSION.dmg
STAGE=$(mktemp -d)
cp -R build/Squish.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Squish $VERSION" -srcfolder "$STAGE" -format UDZO -fs HFS+ "$DMG"
rm -rf "$STAGE"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi
echo "Built $DMG"
