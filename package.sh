#!/bin/bash
#
# Builds the universal plugin (Apple silicon + Intel) and packs it for colleagues:
#   dist/FixDICOM-IsiX-<version>.zip   (TARGET=horos: dist/FixDICOM-Horos-<version>.zip)
#
set -euo pipefail
cd "$(dirname "$0")"

TARGET="${TARGET:-isix}"
if [ "$TARGET" = "horos" ]; then BUILD=build-horos; HOSTNAME=Horos; DIST_FILES=Distribution/Horos
else BUILD=build; HOSTNAME=IsiX; DIST_FILES=Distribution; fi
TARGET="$TARGET" ./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" $BUILD/FixDICOM.osirixplugin/Contents/Info.plist)
NAME="FixDICOM-$HOSTNAME-$VERSION"
STAGE="dist/$NAME"

rm -rf "$STAGE" "dist/$NAME.zip"
mkdir -p "$STAGE"
cp -R $BUILD/FixDICOM.osirixplugin "$STAGE/"
cp "$DIST_FILES/Install FixDICOM.command" "$STAGE/"
chmod +x "$STAGE/Install FixDICOM.command"
sed "s/@VERSION@/$VERSION/g" Distribution/README.txt > "$STAGE/README.txt"
cp LICENSE "$STAGE/LICENSE.txt"

codesign --verify --deep "$STAGE/FixDICOM.osirixplugin"
echo "==> Architectures: $(lipo -archs "$STAGE/FixDICOM.osirixplugin/Contents/MacOS/FixDICOM")"
(cd dist && ditto -c -k --sequesterRsrc --keepParent "$NAME" "$NAME.zip")
echo "==> Package: $(pwd)/dist/$NAME.zip"
