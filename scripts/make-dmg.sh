#!/usr/bin/env bash
# Builds an unsigned (ad-hoc), universal Pet Chat and packages it as dist/PetChat-<version>.dmg.
# ponytail: no Developer ID / notarization yet — users approve the first launch with Open Anyway.
set -euo pipefail
version="${1:?usage: scripts/make-dmg.sh <version, e.g. 0.1.0>}"
build_number="${GITHUB_RUN_NUMBER:-1}"
root="$(cd "$(dirname "$0")/.." && pwd)"
derived="$root/build/release-derived"
stage="$root/build/dmg-stage"
out="$root/dist/PetChat-$version.dmg"

rm -rf "$derived" "$stage" "$out"
mkdir -p "$stage" "$root/dist"

xcodebuild build -project "$root/PetChat.xcodeproj" -scheme PetChat -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$derived" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES

app="$derived/Build/Products/Release/PetChat.app"
archs="$(lipo -archs "$app/Contents/MacOS/PetChat")"
[[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "expected universal binary, got: $archs" >&2; exit 1; }
codesign --verify --deep --strict "$app"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$version" ]]

ditto "$app" "$stage/PetChat.app"
ln -s /Applications "$stage/Applications"
hdiutil create -volname "Pet Chat" -srcfolder "$stage" -fs HFS+ -format UDZO "$out" >/dev/null
hdiutil verify "$out" >/dev/null
echo "$out"
