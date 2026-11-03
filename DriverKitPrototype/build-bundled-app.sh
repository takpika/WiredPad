#!/bin/zsh
set -euo pipefail

: "${WIREPAD_BUNDLE_PREFIX:?Set a bundle prefix you own, for example com.example.wiredpad}"
: "${WIREPAD_TEAM_ID:?Set your Apple Developer Team ID}"
: "${WIREPAD_DRIVER_PROFILE:?Set your DriverKit provisioning profile name}"
: "${WIREPAD_HOST_PROFILE:?Set your Mac app provisioning profile name}"
: "${WIREPAD_SIGNING_IDENTITY:?Set your Apple Development certificate name or SHA-1}"

project_root="$(cd "$(dirname "$0")/.." && pwd)"
driver_root="$project_root/DriverKitPrototype"
derived_root="${WIREPAD_DERIVED_ROOT:-/private/tmp/WiredPadDerivedData}"
driver_id="${WIREPAD_DRIVER_BUNDLE_ID:-$WIREPAD_BUNDLE_PREFIX.WiredPadTouchDriver}"
host_id="${WIREPAD_HOST_BUNDLE_ID:-$WIREPAD_BUNDLE_PREFIX.WiredPadMac}"

xcodegen generate --spec "$project_root/project.yml"
xcodegen generate --spec "$driver_root/project.yml"

xcodebuild -quiet \
  -project "$driver_root/WiredPadDriverPrototype.xcodeproj" \
  -scheme WiredPadTouchDriver \
  -configuration Debug \
  -destination 'generic/platform=DriverKit' \
  -derivedDataPath "$derived_root/Driver" \
  PRODUCT_BUNDLE_IDENTIFIER="$driver_id" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$WIREPAD_TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$WIREPAD_DRIVER_PROFILE" \
  CODE_SIGN_IDENTITY="$WIREPAD_SIGNING_IDENTITY" \
  CODE_SIGNING_ALLOWED=YES build

xcodebuild -quiet \
  -project "$project_root/WiredPad.xcodeproj" \
  -scheme WiredPadMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_root/Mac" \
  PRODUCT_BUNDLE_IDENTIFIER="$host_id" \
  CODE_SIGN_ENTITLEMENTS=Mac/WiredPadMac-DriverKit.entitlements \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$WIREPAD_TEAM_ID" \
  PROVISIONING_PROFILE_SPECIFIER="$WIREPAD_HOST_PROFILE" \
  CODE_SIGN_IDENTITY="$WIREPAD_SIGNING_IDENTITY" \
  CODE_SIGNING_ALLOWED=YES build

app="$derived_root/Mac/Build/Products/Debug/WiredPadMac.app"
dext="$derived_root/Driver/Build/Products/Debug-driverkit/WiredPadTouchDriver.dext"
rm -rf "$app/Contents/Library/SystemExtensions"
mkdir -p "$app/Contents/Library/SystemExtensions"
ditto "$dext" "$app/Contents/Library/SystemExtensions/$driver_id.dext"
/usr/bin/clang -O2 -mmacosx-version-min=15.0 -framework CoreGraphics -framework CoreFoundation \
  "$project_root/Mac/DisplayModeHelper.c" -o "$app/Contents/MacOS/WiredPadModeHelper"
codesign --force --sign "$WIREPAD_SIGNING_IDENTITY" --options runtime \
  "$app/Contents/MacOS/WiredPadModeHelper"
# The sudo PAM module and its installer, which the app runs with administrator rights.
/usr/bin/clang -O2 -bundle -mmacosx-version-min=15.0 -arch arm64e -arch x86_64 \
  -framework Security -framework CoreFoundation -lpam \
  "$project_root/PAM/pam_wiredpad.c" -o "$app/Contents/Resources/pam_wiredpad.so"
codesign --force --sign "$WIREPAD_SIGNING_IDENTITY" "$app/Contents/Resources/pam_wiredpad.so"
cp "$project_root/PAM/install.sh" "$app/Contents/Resources/install-sudo.sh"
codesign --force --sign "$WIREPAD_SIGNING_IDENTITY" \
  --entitlements "$project_root/Mac/WiredPadMac-DriverKit.entitlements" \
  --options runtime "$app"
codesign --verify --strict --verbose=2 "$app"
print -r -- "$app"
