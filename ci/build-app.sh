#!/usr/bin/env bash
# Builds everything:
#   build/payload/HG Deploy.app   the Recovery app (Objective-C, Intel, macOS 10.11+)
#   build/payload/HGFirstBoot.pkg the first-boot package (account, name, SSH)
#   build/HG Deploy Builder.app   the SwiftUI Builder, with the payload inside
#
#   ci/build-app.sh [version] [build-number]
# Works the same on a dev Mac: ci/build-app.sh && open "build/HG Deploy Builder.app"
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(tr -d '[:space:]' < VERSION)}"
BUILD="${2:-1}"
PAYLOAD=build/payload
APP="build/HG Deploy Builder.app"

make_icns() {   # make_icns <1024.png> <out.icns>
  local set; set="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$set"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$1" --out "$set/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$1" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$set" -o "$2"
}

rm -rf build/payload "$APP"
mkdir -p "$PAYLOAD"

# --- HG Deploy (Recovery app) ---
# Objective-C + AppKit only, so it runs in every Recovery from 10.11 up
# (old Recoveries have no Swift runtime).
DEPLOY="$PAYLOAD/HG Deploy.app"
mkdir -p "$DEPLOY/Contents/MacOS" "$DEPLOY/Contents/Resources"
xcrun clang -arch x86_64 -mmacosx-version-min=10.11 -fobjc-arc -O2 -Wall -Wno-deprecated-declarations \
  -framework Cocoa -framework IOKit \
  Deploy/main.m Deploy/AppDelegate.m Deploy/HGSystem.m Deploy/HGShell.m \
  -o "$DEPLOY/Contents/MacOS/HG Deploy"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Deploy/Info.plist > "$DEPLOY/Contents/Info.plist"
printf 'APPL????' > "$DEPLOY/Contents/PkgInfo"
cp Shared/models.json "$DEPLOY/Contents/Resources/models.json"
make_icns Deploy/AppIcon-1024.png "$DEPLOY/Contents/Resources/AppIcon.icns"
lipo -info "$DEPLOY/Contents/MacOS/HG Deploy"
otool -l "$DEPLOY/Contents/MacOS/HG Deploy" | grep -A3 -E "LC_VERSION_MIN_MACOSX|LC_BUILD_VERSION" | head -6

# --- First-boot package ---
FB=build/firstboot
rm -rf "$FB" && mkdir -p "$FB"
ditto FirstBoot/payload "$FB/root"
find "$FB/root" -name .DS_Store -delete
chmod 755 "$FB/root/Library/HGDeploy" "$FB/root/Library/HGDeploy/firstboot.sh"
chmod 644 "$FB/root/Library/LaunchDaemons/com.hgcellular.deploy.firstboot.plist"
ditto FirstBoot/scripts "$FB/scripts"
chmod 755 "$FB/scripts/postinstall"
pkgbuild --root "$FB/root" --scripts "$FB/scripts" --identifier com.hgcellular.deploy.firstboot \
  --version "$VERSION" --install-location / --ownership recommended "$FB/component.pkg"
# startosinstall --installpackage wants a product archive (distribution package).
productbuild --package "$FB/component.pkg" "$PAYLOAD/HGFirstBoot.pkg"
cp Shared/models.json "$PAYLOAD/models.json"

# --- Builder ---
ARCH_ARGS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCH_ARGS[@]}"
BIN_DIR=$(swift build -c release "${ARCH_ARGS[@]}" --show-bin-path)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/HGDeployBuilder" "$APP/Contents/MacOS/HGDeployBuilder"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
# The HG SSO app secret comes from the HGDEPLOY_SSO_SECRET repo secret, never
# from the source. Without it the Builder can't sign anyone in.
if [ -n "${HGDEPLOY_SSO_SECRET:-}" ]; then
  plutil -insert HGSSOAppSecret -string "$HGDEPLOY_SSO_SECRET" "$APP/Contents/Info.plist"
  echo "sso=yes" >> "${GITHUB_OUTPUT:-/dev/null}"
else
  echo "::warning::HGDEPLOY_SSO_SECRET not set - this Builder can't sign in to HG SSO"
  echo "sso=no" >> "${GITHUB_OUTPUT:-/dev/null}"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"
make_icns Resources/AppIcon-1024.png "$APP/Contents/Resources/AppIcon.icns"
ditto "$PAYLOAD" "$APP/Contents/Resources/Payload"

echo "Built $APP ($VERSION build $BUILD)"
