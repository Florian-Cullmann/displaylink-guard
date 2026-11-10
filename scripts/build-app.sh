#!/bin/bash
# Build a universal app. Release mode requires Developer ID signing and notarization.
set -euo pipefail
project_dir="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project_dir"
mode=${1:---development}
case "$mode" in --development|--release) ;; *) echo 'Usage: build-app.sh [--development|--release]' >&2; exit 1 ;; esac
version=${APP_VERSION:-0.2.0}
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'APP_VERSION must be x.y.z' >&2; exit 1; }
if [[ "$mode" == --release ]]; then
    : "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to a notarytool keychain profile}"
    [[ "$SIGNING_IDENTITY" == 'Developer ID Application:'* ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 1; }
fi
output="$project_dir/dist"
build_root="$project_dir/.build/app-package"
mkdir -p "$output" "$build_root"
staging=$(mktemp -d "$build_root/stage.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/DisplayLink Guard.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Helpers"
for arch in arm64 x86_64; do
    swift build -c release --triple "$arch-apple-macosx13.0" --scratch-path "$build_root/$arch"
done
for product in DisplayLinkGuardApp displaylink-guard; do
    destination="$app/Contents/Helpers/$product"
    [[ "$product" != DisplayLinkGuardApp ]] || destination="$app/Contents/MacOS/$product"
    /usr/bin/lipo -create \
        "$build_root/arm64/arm64-apple-macosx/release/$product" \
        "$build_root/x86_64/x86_64-apple-macosx/release/$product" -output "$destination"
    chmod 0755 "$destination"
done
cp scripts/permission.sh "$app/Contents/Resources/permission.sh"
cp LICENSE "$app/Contents/Resources/LICENSE"
swift scripts/make-icon.swift "$staging/AppIcon.iconset"
iconutil -c icns "$staging/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>de.fcullmann.displaylink-guard.app</string>
<key>CFBundleExecutable</key><string>DisplayLinkGuardApp</string>
<key>CFBundleName</key><string>DisplayLink Guard</string>
<key>CFBundleDisplayName</key><string>DisplayLink Guard</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$version</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Copyright © 2026 Florian Cullmann. MIT License.</string>
</dict></plist>
PLIST
identity=-
sign_options=(--options runtime)
if [[ "$mode" == --release ]]; then
    identity=$SIGNING_IDENTITY
    sign_options=(--options runtime --timestamp)
fi
codesign --force --sign "$identity" "${sign_options[@]}" "$app/Contents/Helpers/displaylink-guard"
codesign --force --sign "$identity" "${sign_options[@]}" "$app"
codesign --verify --deep --strict "$app"
if [[ "$mode" == --release ]]; then
    ditto -c -k --keepParent "$app" "$staging/notarize.zip"
    xcrun notarytool submit "$staging/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose "$app"
fi
artifact="DisplayLink-Guard-$version"
[[ "$mode" != --development ]] || artifact="$artifact-development"
# The app is copied out for local UI inspection as well as packaged for download.
[[ ! -e "$output/DisplayLink Guard.app" ]] || rm -rf "$output/DisplayLink Guard.app"
ditto "$app" "$output/DisplayLink Guard.app"
mkdir "$staging/dmg"
ditto "$app" "$staging/dmg/DisplayLink Guard.app"
ln -s /Applications "$staging/dmg/Applications"
hdiutil create -quiet -volname 'DisplayLink Guard' -srcfolder "$staging/dmg" -format UDZO -ov "$output/$artifact.dmg"
if [[ "$mode" == --release ]]; then
    codesign --force --sign "$identity" --timestamp "$output/$artifact.dmg"
    xcrun notarytool submit "$output/$artifact.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$output/$artifact.dmg"
    xcrun stapler validate "$output/$artifact.dmg"
    spctl --assess --type open --context context:primary-signature --verbose "$output/$artifact.dmg"
fi
(cd "$output" && shasum -a 256 "$artifact.dmg" > "$artifact.dmg.sha256")
printf '\nBuilt %s/%s.dmg\n' "$output" "$artifact"
if [[ "$mode" == --development ]]; then
    echo 'Development build only: not notarized; do not publish as a signed installer.'
fi
